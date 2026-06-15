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
            onProgress("Failed to create Android Virtual Device (AVD).", false)
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
                       !l.hasPrefix("hw.lcd.density")
            }
            lines.append("hw.lcd.width=\(profile.width)")
            lines.append("hw.lcd.height=\(profile.height)")
            lines.append("hw.lcd.density=\(profile.density)")
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
        guard emulatorInstalled else { return false }

        var args = ["-avd", name, "-gpu", "host", "-memory", "2048", "-dns-server", "8.8.8.8"]
        if headless {
            args += ["-no-window", "-no-audio", "-no-boot-anim"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: emulatorPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
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
        return true
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

    /// Delete a virtual device and its data.
    @discardableResult
    public func deleteAVD(name: String) -> Shell.Result {
        Shell.run([cmdlineTool("avdmanager"), "delete", "avd", "-n", name])
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
