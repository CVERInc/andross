import Foundation

public final class EmulatorManager: Sendable {
    public static let shared = EmulatorManager()

    /// SDK root installed by the `android-commandlinetools` Homebrew cask.
    public let androidHome = "/opt/homebrew/share/android-commandlinetools"

    private init() {}

    // MARK: - Spawned-process registry
    //
    // An emulator that is still booting has NOT yet registered with adb, so
    // `stopAll()` (which only sees adb-visible serials) cannot kill it — the
    // user presses "stop" and an orphan emulator keeps booting in the
    // background. We therefore keep weak-ish handles to every emulator process
    // we spawn, so a stop can also terminate boots that are still in flight.
    private let liveProcessesLock = NSLock()
    nonisolated(unsafe) private var _liveProcesses: [Process] = []

    private func registerSpawned(_ process: Process) {
        liveProcessesLock.lock()
        defer { liveProcessesLock.unlock() }
        _liveProcesses = ProcessRegistry.pruned(_liveProcesses)
        _liveProcesses.append(process)
    }

    /// Terminate (SIGTERM) every emulator process we spawned that is still
    /// running, and drop dead handles. Returns the number signalled. This is
    /// the half of shutdown that reaches boots adb can't see yet.
    @discardableResult
    public func terminateSpawnedProcesses() -> Int {
        liveProcessesLock.lock()
        defer { liveProcessesLock.unlock() }
        let signalled = ProcessRegistry.terminateRunning(_liveProcesses)
        _liveProcesses = ProcessRegistry.pruned(_liveProcesses)
        return signalled
    }

    /// Number of spawned emulator processes still running (after pruning dead
    /// handles). Useful for shutdown bookkeeping and status display.
    public var liveSpawnedCount: Int {
        liveProcessesLock.lock()
        defer { liveProcessesLock.unlock() }
        _liveProcesses = ProcessRegistry.pruned(_liveProcesses)
        return _liveProcesses.count
    }

    // MARK: - Tool resolution
    //
    // The cask only symlinks avdmanager/sdkmanager into /opt/homebrew/bin.
    // `emulator` and `adb` are downloaded later by sdkmanager and live inside
    // the SDK root, so they are NOT on PATH. A second, unrelated adb from the
    // `android-platform-tools` cask may also be on PATH; mismatched adb
    // versions restart each other's server, so we always prefer the SDK's own.

    public var emulatorPath: String { androidHome + "/emulator/emulator" }

    public var adbPath: String {
        let sdkAdb = androidHome + "/platform-tools/adb"
        return FileManager.default.fileExists(atPath: sdkAdb) ? sdkAdb : "adb"
    }

    /// Resolve a cmdline-tools binary (sdkmanager / avdmanager), preferring
    /// the SDK-rooted absolute path and falling back to PATH lookup.
    public func cmdlineTool(_ name: String) -> String {
        let path = androidHome + "/cmdline-tools/latest/bin/" + name
        return FileManager.default.fileExists(atPath: path) ? path : name
    }

    /// True once `sdkmanager emulator platform-tools` has been installed.
    public var emulatorInstalled: Bool {
        FileManager.default.fileExists(atPath: emulatorPath)
    }

    /// Check if system dependencies are satisfied.
    /// - Returns: Tuple containing (brewInstalled, javaInstalled, sdkInstalled)
    public func checkStatus() -> (brew: Bool, java: Bool, sdk: Bool) {
        let brew = Shell.run(["which", "brew"]).ok
        let java = Shell.run(["java", "-version"]).ok
        let sdk = FileManager.default.fileExists(atPath: androidHome)
        return (brew, java, sdk)
    }

    /// Install Java environment via Homebrew.
    @discardableResult
    public func installJava(onLine: @escaping @Sendable (String, Bool) -> Void) -> Bool {
        Shell.runStreaming(["brew", "install", "--cask", "temurin"], onLine: onLine).ok
    }

    /// Install Android SDK Command-line Tools via Homebrew.
    @discardableResult
    public func installSdk(onLine: @escaping @Sendable (String, Bool) -> Void) -> Bool {
        Shell.runStreaming(["brew", "install", "--cask", "android-commandlinetools"], onLine: onLine).ok
    }

    // MARK: - Device enumeration

    /// Serials of all emulators currently visible to adb (booted enough to register).
    public func connectedEmulators() -> [String] {
        let result = Shell.run([adbPath, "devices"])
        guard result.ok else { return [] }
        return AndrossParse.emulatorSerials(from: result.stdout)
    }

    /// Map running emulator serials to the AVD names they were booted from.
    public func runningAVDs() -> [(serial: String, avdName: String)] {
        connectedEmulators().compactMap { serial in
            let result = adb(serial, ["emu", "avd", "name"])
            guard result.ok else { return nil }
            // Output is the AVD name on the first line, then "OK".
            let name = result.stdout
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : (serial, name)
        }
    }

    /// Block until the device has fully booted (sys.boot_completed == 1).
    @discardableResult
    public func waitForBoot(serial: String, timeoutSeconds: Int = 180) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            let result = adb(serial, ["shell", "getprop", "sys.boot_completed"])
            if result.ok && AndrossParse.bootCompleted(from: result.stdout) {
                return true
            }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }

    /// Wait for any emulator to appear and finish booting; returns its serial.
    public func waitForBootedEmulator(timeoutSeconds: Int = 240) -> String? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let serial = connectedEmulators().first {
                let remaining = Int(deadline.timeIntervalSinceNow)
                return waitForBoot(serial: serial, timeoutSeconds: max(remaining, 10)) ? serial : nil
            }
            Thread.sleep(forTimeInterval: 2)
        }
        return nil
    }

    /// Run an adb command pinned to a specific device serial.
    @discardableResult
    func adb(_ serial: String, _ args: [String], stdin: String? = nil) -> Shell.Result {
        Shell.run([adbPath, "-s", serial] + args, stdin: stdin)
    }

    // MARK: - AVD lifecycle

    /// Scan and return a list of created Android Virtual Devices (AVD).
    public func listAVDs() -> [String] {
        let result = Shell.run([cmdlineTool("avdmanager"), "list", "avd"])
        guard result.ok else { return [] }
        return AndrossParse.avdNames(from: result.stdout)
    }

    /// Map each AVD id to the human name to show for it, read from the AVD's
    /// config.ini (`avd.ini.displayname`). Ids with no stored display name map
    /// to themselves, so a caller can always resolve *some* name.
    public func avdDisplayNames(for ids: [String]) -> [String: String] {
        let avdRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".android").appendingPathComponent("avd")
        var map: [String: String] = [:]
        for id in ids {
            map[id] = id
            let config = avdRoot.appendingPathComponent("\(id).avd")
                .appendingPathComponent("config.ini")
            guard let text = try? String(contentsOf: config, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) where line.hasPrefix("avd.ini.displayname=") {
                let value = String(line.dropFirst("avd.ini.displayname=".count))
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { map[id] = value }
                break
            }
        }
        return map
    }

    /// Supported Android device profile configurations (sizes and orientations)
    public enum DeviceProfile: Int, Sendable, CaseIterable {
        case phonePortrait = 1
        case phoneLandscape = 2
        case tabletPortrait = 3
        case tabletLandscape = 4

        public var width: Int {
            switch self {
            case .phonePortrait: return 1080
            case .phoneLandscape: return 2400
            case .tabletPortrait: return 1600
            case .tabletLandscape: return 2560
            }
        }

        public var height: Int {
            switch self {
            case .phonePortrait: return 2400
            case .phoneLandscape: return 1080
            case .tabletPortrait: return 2560
            case .tabletLandscape: return 1600
            }
        }

        public var density: Int {
            switch self {
            case .phonePortrait, .phoneLandscape: return 440
            case .tabletPortrait, .tabletLandscape: return 320
            }
        }

        public var name: String {
            switch self {
            case .phonePortrait: return "Phone (Portrait)"
            case .phoneLandscape: return "Phone (Landscape)"
            case .tabletPortrait: return "Tablet (Portrait)"
            case .tabletLandscape: return "Tablet (Landscape)"
            }
        }
    }

    /// Supported Android system image configurations
    public enum SystemType: Int, Sendable {
        case googlePlay = 1
        case aospWithAurora = 2
        case aospBlank = 3

        /// SDK package id for this image at the given API level.
        public func sdkImage(apiLevel: Int) -> String {
            switch self {
            case .googlePlay:
                return "system-images;android-\(apiLevel);google_apis_playstore;arm64-v8a"
            case .aospWithAurora, .aospBlank:
                return "system-images;android-\(apiLevel);default;arm64-v8a"
            }
        }
    }

    /// Android API levels offered when creating a device. 34 = Android 14
    /// (current default — broadly compatible); 35 = Android 15.
    public static let supportedAPILevels = [35, 34, 33]
    public static let defaultAPILevel = 34

    /// Create a new virtual device (AVD) and download required SDK components.
    public func createAVD(
        name: String,
        displayName: String,
        type: SystemType,
        profile: DeviceProfile,
        apiLevel: Int = EmulatorManager.defaultAPILevel,
        onProgress: @escaping @Sendable (String, Bool) -> Void
    ) async -> Bool {
        onProgress("Accepting Google SDK licenses...", false)
        Shell.run([cmdlineTool("sdkmanager"), "--licenses"],
                  stdin: String(repeating: "y\n", count: 50))

        let image = type.sdkImage(apiLevel: apiLevel)
        onProgress("Downloading Android system image & emulator binaries, this may take a few minutes...", false)

        let dlResult = Shell.runStreaming(
            [cmdlineTool("sdkmanager"), image, "platform-tools", "emulator"],
            onLine: onProgress)
        guard dlResult.ok else {
            onProgress("Failed to download SDK components. Please check your network connection!", false)
            return false
        }

        onProgress("Creating virtual device '\(name)'...", false)
        let createArgs = [cmdlineTool("avdmanager"), "create", "avd",
                          "-n", name, "-k", image, "--device", "pixel_6", "--force"]
        let createResult = Shell.run(createArgs, stdin: "no\n")

        guard createResult.ok else {
            // Surface the real reason (bad name, missing image, license) rather
            // than a dead-end "failed" — the in-app log is the only breadcrumb.
            let reason = [createResult.stderr, createResult.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }?
                .components(separatedBy: .newlines)
                .first { $0.localizedCaseInsensitiveContains("error") } ?? ""
            onProgress(reason.isEmpty ? "Couldn't create the phone." : "Couldn't create the phone — \(reason)", false)
            return false
        }

        // Write custom resolution config to config.ini
        let configPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".android")
            .appendingPathComponent("avd")
            .appendingPathComponent("\(name).avd")
            .appendingPathComponent("config.ini")

        if FileManager.default.fileExists(atPath: configPath.path),
           let configContent = try? String(contentsOf: configPath, encoding: .utf8) {
            var lines = configContent.components(separatedBy: .newlines)
            lines = lines.filter { line in
                let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !l.hasPrefix("hw.lcd.width") &&
                       !l.hasPrefix("hw.lcd.height") &&
                       !l.hasPrefix("hw.lcd.density") &&
                       !l.hasPrefix("avd.ini.displayname")
            }
            lines.append("hw.lcd.width=\(profile.width)")
            lines.append("hw.lcd.height=\(profile.height)")
            lines.append("hw.lcd.density=\(profile.density)")
            // The clean id above is what avdmanager/adb/emulator use; the name
            // the user actually typed (spaces, CJK, whatever) lives here as the
            // native AVD display name so the UI can show it verbatim.
            if !displayName.isEmpty {
                lines.append("avd.ini.displayname=\(displayName)")
            }
            try? lines.joined(separator: "\n").write(to: configPath, atomically: true, encoding: .utf8)
        }

        // Sideload Aurora Store if required
        if type == .aospWithAurora {
            onProgress("Downloading open-source Aurora Store APK...", false)
            let tmpDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".andross_tmp")
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let apkURL = tmpDir.appendingPathComponent("AuroraStore.apk")

            let downloadCmd = ["curl", "-L", "-o", apkURL.path,
                               "https://files.auroraoss.com/AuroraStore/Stable/AuroraStore-Stable.apk"]
            if Shell.run(downloadCmd).ok {
                onProgress("Aurora Store APK downloaded. It will be automatically installed on first launch.", false)
            } else {
                onProgress("Aurora Store download failed, but the virtual device was successfully created.", false)
            }
        }

        onProgress("Virtual device '\(name)' successfully configured!", false)
        return true
    }

    /// Start a virtual device (AVD) in the background (non-blocking).
    ///
    /// Launches the SDK's emulator binary directly (it is not on PATH).
    /// Returns false when the emulator binary is missing or the process
    /// fails to spawn — it does NOT wait for the boot to finish; use
    /// `waitForBootedEmulator()` for that.
    @discardableResult
    public func startAVD(name: String, headless: Bool = false) -> Bool {
        startAVDObserved(name: name, headless: headless) != nil
    }

    /// Start an AVD and hand back a handle that watches how the launch turns
    /// out. Unlike `startAVD`, which only reports whether the process *spawned*,
    /// the returned observation captures the emulator's stderr and its early
    /// exit — so a launch that dies a second later (e.g. "not enough disk
    /// space") can be surfaced instead of vanishing. Returns nil only when the
    /// engine is missing or the process fails to even start.
    public func startAVDObserved(name: String, headless: Bool = false) -> LaunchObservation? {
        guard emulatorInstalled else { return nil }

        var args = ["-avd", name, "-gpu", "host", "-memory", "2048", "-dns-server", "8.8.8.8"]
        if headless {
            // No window and no boot animation, but keep audio: the embedded
            // screen streams the phone's sound over scrcpy, and `-no-audio`
            // would leave the guest with no audio device to capture.
            args += ["-no-window", "-no-boot-anim"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: emulatorPath)
        process.arguments = args

        // Capture stderr (bounded) so a fatal reason is readable; a booted
        // emulator is long-lived and chatty, so the observation caps what it
        // keeps rather than buffering the whole session.
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        let observation = LaunchObservation()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil   // EOF
            } else {
                observation.appendStderr(data)
            }
        }
        process.terminationHandler = { proc in
            observation.markExited(proc.terminationStatus)
            errPipe.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try process.run()
        } catch {
            return nil
        }
        registerSpawned(process)

        // If a pending Aurora Store APK exists, install it once the device boots.
        let tmpDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".andross_tmp")
        let apkURL = tmpDir.appendingPathComponent("AuroraStore.apk")
        if FileManager.default.fileExists(atPath: apkURL.path) {
            Task.detached { [self] in
                guard let serial = waitForBootedEmulator() else { return }
                if adb(serial, ["install", apkURL.path]).ok {
                    try? FileManager.default.removeItem(at: apkURL)
                }
            }
        }
        return observation
    }

    /// Race a freshly-launched emulator to one of three ends: it registers with
    /// adb and finishes booting (`.booted`), its process dies before any device
    /// appears (`.failed`, with the reason distilled from stderr), or neither
    /// happens in time (`.timedOut`). This is the observation `startAVDObserved`
    /// enables — call it off the main thread; it blocks.
    public func awaitLaunchOutcome(_ observation: LaunchObservation,
                                   timeoutSeconds: Int = 240) -> LaunchOutcome {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let serial = connectedEmulators().first {
                let remaining = max(Int(deadline.timeIntervalSinceNow), 10)
                return waitForBoot(serial: serial, timeoutSeconds: remaining)
                    ? .booted(serial)
                    : .timedOut
            }
            // Died before any device registered — a real launch failure, not a
            // slow boot. The disk-space FATAL lands here (~1s after spawn).
            if observation.hasExited {
                return .failed(AndrossParse.emulatorFailureReason(from: observation.stderrText))
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return .timedOut
    }

    /// Gracefully terminate all running emulator instances.
    ///
    /// Asks every adb-visible emulator to quit (`emu kill`), then also
    /// terminates any emulator process we spawned that is still booting and so
    /// hasn't registered with adb yet — without this an in-flight boot would
    /// survive a "stop" as an orphan. The two sets overlap for booted devices;
    /// a doubled terminate on an already-quitting process is harmless.
    /// - Returns: Number of adb-visible emulators that were asked to shut down.
    @discardableResult
    public func stopAll() -> Int {
        let serials = connectedEmulators()
        for serial in serials {
            adb(serial, ["emu", "kill"])
        }
        terminateSpawnedProcesses()
        return serials.count
    }

    /// Move a virtual device to the Trash — recoverable, unlike `avdmanager
    /// delete avd`, which erases the `.avd` in place with no way back (it cost
    /// a phone once). The caller shuts the phone down first; a running AVD holds
    /// its files open. Returns false if any piece couldn't be trashed.
    @discardableResult
    public func deleteAVD(name: String) -> Bool {
        let avdHome = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".android")
            .appendingPathComponent("avd")
        let pieces = [avdHome.appendingPathComponent("\(name).avd"),
                      avdHome.appendingPathComponent("\(name).ini")]
        var ok = true
        for url in pieces where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                ok = false
            }
        }
        return ok
    }

    /// Install a local APK file to the given emulator.
    /// - Parameter userId: restrict the install to one identity; nil installs
    ///   for all identities (data stays isolated per identity either way).
    @discardableResult
    public func installAPK(serial: String, path: String, userId: Int? = nil,
                           onLine: @escaping @Sendable (String, Bool) -> Void) -> Bool {
        onLine("Installing \(URL(fileURLWithPath: path).lastPathComponent)...", false)
        var args = [adbPath, "-s", serial, "install"]
        if let userId { args += ["--user", "\(userId)"] }
        args.append(path)
        return Shell.runStreaming(args, onLine: onLine).ok
    }

    // MARK: - Uninstallation / Purging (Clean Uninstall)

    /// Uninstall Android SDK Command-line Tools via Homebrew.
    @discardableResult
    public func uninstallSdk(onLine: @escaping @Sendable (String, Bool) -> Void) -> Bool {
        Shell.runStreaming(["brew", "uninstall", "--cask", "android-commandlinetools"], onLine: onLine).ok
    }

    /// Uninstall Java (Temurin JRE) via Homebrew.
    @discardableResult
    public func uninstallJava(onLine: @escaping @Sendable (String, Bool) -> Void) -> Bool {
        Shell.runStreaming(["brew", "uninstall", "--cask", "temurin"], onLine: onLine).ok
    }

    /// Purge Android Virtual Devices (AVD) and configurations directory.
    @discardableResult
    public func purgeAVDFiles() -> Bool {
        removeHomeDirectoryItem(".android")
    }

    /// Purge temporary files generated by andross (~/.andross_tmp).
    @discardableResult
    public func purgeTempFiles() -> Bool {
        removeHomeDirectoryItem(".andross_tmp")
    }

    private func removeHomeDirectoryItem(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Host file sizes

    /// Calculate size of a directory on the macOS host in bytes.
    public func getDirectorySize(path: String) -> Int64 {
        let result = Shell.run(["du", "-sk", path])
        guard result.ok, let bytes = AndrossParse.duBytes(from: result.stdout) else { return 0 }
        return bytes
    }

    /// Get size of a file on the macOS host in bytes.
    public func getFileSize(path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.size] as? Int64 ?? 0
    }

    // MARK: - Free space

    /// Bytes free on the volume that holds the AVDs. Uses statfs-style free size
    /// (not the optimistic "important usage" figure) so it tracks the same
    /// number the emulator's own boot-time disk check sees, and returns
    /// `.max` if the volume can't be probed (never a false "disk full").
    public func availableDiskBytes() -> Int64 {
        let path = URL(fileURLWithPath: NSHomeDirectory()).path
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? Int64 else { return .max }
        return free
    }

    /// The emulator aborts its own boot below roughly this much free space
    /// ("not enough disk space to run avd"). We gate a touch below that so a
    /// boot with real headroom is never blocked, and lean on the launch-failure
    /// surface to catch the narrow margin above it.
    public static let minBootFreeBytes: Int64 = 2 * 1024 * 1024 * 1024
}

/// How a launched emulator turned out. See `awaitLaunchOutcome`.
public enum LaunchOutcome: Sendable, Equatable {
    /// Booted and reachable at this adb serial.
    case booted(String)
    /// The engine stopped before a device appeared; carries a human reason.
    case failed(String)
    /// Neither booted nor failed within the allotted time.
    case timedOut
}

/// A live handle onto a launching emulator: its (bounded) stderr and whether
/// its process has exited. The emulator process writes from a background
/// thread while the launch-watcher reads from another, so every access is
/// lock-guarded — hence `@unchecked Sendable`.
public final class LaunchObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var _stderr = Data()
    private var _exited = false

    /// Keep only the tail: a fatal reason is emitted early and briefly, while a
    /// booted emulator would otherwise stream megabytes over its lifetime.
    private static let stderrCap = 32 * 1024

    func appendStderr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        _stderr.append(data)
        if _stderr.count > Self.stderrCap {
            _stderr = _stderr.suffix(Self.stderrCap)
        }
    }

    func markExited(_ status: Int32) {
        lock.lock(); defer { lock.unlock() }
        _exited = true
    }

    public var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }
        return _exited
    }

    public var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: _stderr, encoding: .utf8) ?? ""
    }
}

/// Pure bookkeeping for the spawned-emulator-process registry, split out so
/// the keep/terminate logic can be unit-tested with real (non-emulator)
/// processes and without touching the shared singleton's lock.
public enum ProcessRegistry {
    /// Drop handles to processes that are no longer running.
    public static func pruned(_ processes: [Process]) -> [Process] {
        processes.filter { $0.isRunning }
    }

    /// SIGTERM every still-running process; return how many were signalled.
    @discardableResult
    public static func terminateRunning(_ processes: [Process]) -> Int {
        var signalled = 0
        for process in processes where process.isRunning {
            process.terminate()
            signalled += 1
        }
        return signalled
    }
}
