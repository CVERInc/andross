import SwiftUI
import AppKit
import AndrossCore
import UniformTypeIdentifiers
import Signet

// The android-green / slate palette and Color(hex:) now come from Signet
// (the shared design system); andross's values live there as AndrossTheme.

extension View {
    func liquidGlassBackground(cornerRadius: CGFloat = 8, customBorderColor: Color? = nil) -> some View {
        self
            .background(Color.white.opacity(0.05))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        customBorderColor ?? Color.white.opacity(0.12),
                        lineWidth: 1
                    )
            )
    }
}

/// Receives .apk files opened from Finder (double-click / drag onto the
/// app icon) — the thin Android just runs whatever you hand it.
final class AndrossAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "apk" {
            Task { @MainActor in
                AppModel.shared.handleIncomingAPK(url)
            }
        }
    }

    // Some launch paths still deliver documents through the legacy API.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard url.pathExtension.lowercased() == "apk" else { return false }
        Task { @MainActor in
            AppModel.shared.handleIncomingAPK(url)
        }
        return true
    }

    // Quitting andross shouldn't leave a booted emulator running as an
    // orphan process — stop everything first, then let the app finish
    // quitting. stopAll() shells out to adb, so it's kept off the main
    // thread and the app waits for it via .terminateLater.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = EmulatorManager.shared.stopAll()
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    // The native red traffic light just closes the window (AppKit's default
    // performClose: behavior) — it does not quit the app on its own. This is
    // a single-window utility, so closing the only window should still quit
    // (and therefore still run applicationShouldTerminate above).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AndrossApp: App {
    @NSApplicationDelegateAdaptor(AndrossAppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("andross") {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(.androidGreen)
                .cverTheme(AndrossTheme())
                .background(Color.clear)
                // SwiftUI lifecycle delivers Finder-opened documents here,
                // not to the app delegate's open-urls callback.
                .onOpenURL { url in
                    if url.pathExtension.lowercased() == "apk" {
                        AppModel.shared.handleIncomingAPK(url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

// GUI State Control Model
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var avds: [String] = []
    @Published var selectedAVD: String?
    @Published var logs: [String] = []
    @Published var isCreating = false
    @Published var progressMessage = ""
    @Published var isDragging = false
    @Published var depStatus = (brew: true, java: true, sdk: true)
    
    // Identity (Tank) Management State
    @Published var identities: [EmulatorManager.AndroidUser] = []
    @Published var activeIdentityId: Int = 0
    @Published var activeDeviceName = ""
    @Published var activeSerial: String? = nil
    @Published var ownerPackages: [String] = []
    @Published var activePackages: [String] = []
    @Published var runningAVDNames: Set<String> = []
    /// App waiting for the phone to finish booting (tile tapped while off).
    @Published var pendingLaunch: String? = nil
    /// Last-known apps, so the home grid survives the phone being off.
    @Published var cachedPackages: [String] = UserDefaults.standard.stringArray(forKey: "cachedPackages") ?? []

    /// What the home grid shows: live list when the phone is on,
    /// last-known list when it's off.
    var homePackages: [String] { activeSerial != nil ? activePackages : cachedPackages }
    
    // Storage statistics
    @Published var hostAppSize = ""
    @Published var hostAvdSize = ""
    @Published var hostTempSize = ""
    @Published var appStorageStats: [EmulatorManager.AppStorageStats] = []
    
    // Variables for creating new phones and identities
    @Published var newName = ""
    @Published var newType = 1 // 1: Play Store, 2: AOSP+Aurora, 3: Blank AOSP
    @Published var newProfile = 1 // 1: Phone Portrait, 2: Phone Landscape, 3: Tablet Portrait, 4: Tablet Landscape
    @Published var newAPILevel = EmulatorManager.defaultAPILevel
    
    // Clean uninstallation configuration
    @Published var showUninstallSheet = false
    @Published var uninstallDeleteAVDs = true
    @Published var uninstallSdk = false
    @Published var uninstallJava = false
    @Published var uninstallTemp = true
    
    // Desktop layout state — system surfaces live in the dock; the home
    // grid belongs to the user's own Android apps.
    enum ActiveApp: String, CaseIterable, Sendable {
        case devices
        case sandboxes
        case settings
        case screen
    }

    /// Boot phones without a separate emulator window; the phone lives in
    /// the embedded Screen view instead (beta).
    @Published var headlessBoot = UserDefaults.standard.bool(forKey: "headlessBoot") {
        didSet { UserDefaults.standard.set(headlessBoot, forKey: "headlessBoot") }
    }
    
    @Published var rememberWindowPosition = UserDefaults.standard.bool(forKey: "rememberWindowPosition") {
        didSet { UserDefaults.standard.set(rememberWindowPosition, forKey: "rememberWindowPosition") }
    }
    
    @Published var activeApp: ActiveApp? = nil

    /// The size/rotation picker anchored to the green light. Lives on the model
    /// because the green light and the menu render in different hosting views.
    @Published var sizeMenuVisible = false

    /// Mutes the streamed phone's audio — the island's stand-in for the ring/
    /// silent switch. Lives on the model because the island button that flips it
    /// and the AudioPlayer that honours it are worlds apart; persisted so the
    /// phone stays as loud or as quiet as you last left it. Applied via the
    /// player's gain, so muting never interrupts the stream.
    @Published var audioMuted = UserDefaults.standard.bool(forKey: "audioMuted") {
        didSet { UserDefaults.standard.set(audioMuted, forKey: "audioMuted") }
    }

    // Default to Phone Portrait on launch
    @Published var isTablet = false
    @Published var isLandscape = false

    /// The app's one window, handed over by WindowConfigurator. Weak: the model
    /// outlives the window and has no business keeping it alive.
    weak var mainWindow: NSWindow?

    /// Width / height of the live stream, published by the embedded screen the
    /// moment scrcpy reports the session's real dimensions. While the screen is
    /// open the window takes its shape from this instead of the size preset —
    /// that is what keeps the phone bar-free on any device.
    @Published var streamAspect: CGFloat?

    var currentWidth: CGFloat { currentWindowSize.width }
    var currentHeight: CGFloat { currentWindowSize.height }

    /// The preset picks the size; an open screen picks the shape.
    private var currentWindowSize: CGSize {
        let preset = phoneWindowSize(isTablet: isTablet, isLandscape: isLandscape)
        guard activeApp == .screen, let streamAspect else { return preset }
        let fit = embeddedScreenWindowSize(deviceAspect: streamAspect,
                                           longSide: max(preset.width, preset.height))
        return fit.window == .zero ? preset : fit.window
    }

    private var logBuffer = LogBuffer()
    private var refreshTimer: Timer?

    init() {
        refreshAVDs()
        checkDependencies()
        refreshStorageStats()

        // Keep the home screen in sync with reality: a phone booted from
        // here takes a minute to come up, and one stopped from inside the
        // phone window disappears — poll cheaply instead of going stale.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshIdentities()
            }
        }
        // Note: no deinit invalidation — AppModel is the root StateObject and
        // lives for the app's lifetime; the weak self keeps the timer inert
        // if that ever changes.
    }
    
    func refreshAVDs() {
        Task.detached(priority: .userInitiated) {
            let list = EmulatorManager.shared.listAVDs()
            await MainActor.run {
                self.avds = list
                if self.selectedAVD == nil {
                    self.selectedAVD = list.first
                }
            }
        }
        refreshIdentities()
    }
    
    func checkDependencies() {
        depStatus = EmulatorManager.shared.checkStatus()
    }
    
    func log(_ message: String, transient: Bool = false) {
        logBuffer.append(message, transient: transient)
        logs = logBuffer.lines
    }

    func clearLogs() {
        logBuffer.clear()
        logs = logBuffer.lines
    }
    
    func refreshStorageStats() {
        Task.detached(priority: .background) {
            let home = NSHomeDirectory()
            
            // 1. Get andross app size from its own bundle (wherever it lives)
            let appSize = EmulatorManager.shared.getDirectorySize(path: Bundle.main.bundlePath)
            
            // 2. Get AVD size (~/.android)
            let avdPath = URL(fileURLWithPath: home).appendingPathComponent(".android").path
            let avdSize = EmulatorManager.shared.getDirectorySize(path: avdPath)
            
            // 3. Get temp size (~/.andross_tmp)
            let tempPath = URL(fileURLWithPath: home).appendingPathComponent(".andross_tmp").path
            let tempSize = EmulatorManager.shared.getDirectorySize(path: tempPath)
            
            // Format sizes
            let appSizeStr = ByteCountFormatter.string(fromByteCount: appSize, countStyle: .file)
            let avdSizeStr = ByteCountFormatter.string(fromByteCount: avdSize, countStyle: .file)
            let tempSizeStr = ByteCountFormatter.string(fromByteCount: tempSize, countStyle: .file)
            
            // 4. Query third-party packages of the active identity if an emulator is running
            var statsList: [EmulatorManager.AppStorageStats] = []
            let activeUserId = await MainActor.run { self.activeIdentityId }
            let serial = await MainActor.run { self.activeSerial }

            if let serial {
                let packages = EmulatorManager.shared.listThirdPartyPackages(serial: serial, userId: activeUserId)
                for pkg in packages {
                    if let stats = EmulatorManager.shared.getAppStorageStats(serial: serial, packageName: pkg, userId: activeUserId) {
                        statsList.append(stats)
                    }
                }
            }
            
            await MainActor.run {
                self.hostAppSize = appSizeStr
                self.hostAvdSize = avdSizeStr
                self.hostTempSize = tempSizeStr
                self.appStorageStats = statsList
            }
        }
    }
    
    // MARK: - Identity Management
    
    func refreshIdentities() {
        Task.detached(priority: .userInitiated) {
            let manager = EmulatorManager.shared
            let running = manager.runningAVDs()
            let serial = running.first?.serial

            var users: [EmulatorManager.AndroidUser] = []
            var currentId = 0
            var packages: [String] = []
            var currentPackages: [String] = []
            if let serial {
                users = manager.listUsers(serial: serial)
                currentId = manager.currentUserId(serial: serial)
                packages = manager.listThirdPartyPackages(serial: serial, userId: 0)
                currentPackages = currentId == 0
                    ? packages
                    : manager.listThirdPartyPackages(serial: serial, userId: currentId)
            }

            await MainActor.run {
                // Only re-run the (du-heavy) storage scan when the device
                // state actually changed — this runs on a 6s poll.
                let changed = self.activeSerial != serial
                    || self.activeIdentityId != currentId
                    || self.activePackages != currentPackages

                self.activeSerial = serial
                self.identities = users
                self.activeIdentityId = currentId
                self.ownerPackages = packages
                self.activePackages = currentPackages
                self.activeDeviceName = running.first?.avdName ?? ""
                self.runningAVDNames = Set(running.map { $0.avdName })
                if serial != nil, self.cachedPackages != currentPackages {
                    self.cachedPackages = currentPackages
                    UserDefaults.standard.set(currentPackages, forKey: "cachedPackages")
                }
                if changed {
                    self.refreshStorageStats()
                }
            }
        }
    }

    func createIdentity(name: String) {
        guard !name.isEmpty else { return }
        guard let serial = activeSerial else {
            log("No running phone — launch a virtual device first.")
            return
        }
        log("Creating new identity sandbox [\(name)]...")

        Task.detached(priority: .userInitiated) {
            if let newId = EmulatorManager.shared.createUser(serial: serial, name: name) {
                await MainActor.run {
                    self.log("Identity [\(name)] created (ID: \(newId)). Use Clone to enable apps for it.")
                    self.refreshIdentities()
                    self.switchIdentity(id: newId)
                }
            } else {
                await MainActor.run {
                    self.log("Failed to create identity [\(name)].")
                }
            }
        }
    }

    func switchIdentity(id: Int) {
        guard let serial = activeSerial else { return }
        log("Switching screen display focus to identity ID: \(id)...")
        Task.detached(priority: .userInitiated) {
            let ok = EmulatorManager.shared.switchUser(serial: serial, id: id)
            await MainActor.run {
                if ok {
                    self.log("Identity switched successfully.")
                    self.refreshIdentities()
                } else {
                    self.log("Failed to switch identity.")
                }
            }
        }
    }

    func deleteIdentity(id: Int) {
        guard id != 0 else { return } // ID 0 is Owner, cannot be deleted
        guard let serial = activeSerial else { return }
        log("Removing identity ID: \(id)...")
        Task.detached(priority: .userInitiated) {
            let ok = EmulatorManager.shared.deleteUser(serial: serial, id: id)
            await MainActor.run {
                if ok {
                    self.log("Identity removed successfully.")
                    self.refreshIdentities()
                } else {
                    self.log("Failed to remove identity.")
                }
            }
        }
    }

    /// Tile tapped while the phone is off: boot it, then launch the app —
    /// the user never has to think about "booting a phone".
    func bootAndLaunch(packageName: String) {
        guard pendingLaunch == nil else { return }
        guard let name = selectedAVD ?? avds.first else {
            activeApp = .devices
            return
        }
        let headless = headlessBoot
        pendingLaunch = packageName
        log("Starting the phone for \(AppCatalog.displayName(for: packageName))…")
        guard EmulatorManager.shared.startAVD(name: name, headless: headless) else {
            pendingLaunch = nil
            log("Couldn't start the phone — the engine isn't installed yet.")
            return
        }
        Task.detached(priority: .userInitiated) {
            let serial = EmulatorManager.shared.waitForBootedEmulator(timeoutSeconds: 240)
            var launched = false
            if let serial {
                launched = EmulatorManager.shared.launchUntilForeground(
                    serial: serial, packageName: packageName)
            }
            await MainActor.run {
                self.pendingLaunch = nil
                if let serial {
                    self.activeSerial = serial
                    self.refreshIdentities()
                    if launched && headless {
                        withAnimation(.easeIn(duration: 0.15)) { self.activeApp = .screen }
                    } else if !launched {
                        self.log("\(AppCatalog.displayName(for: packageName)) didn't open — tap it again.")
                    }
                } else {
                    self.log("The phone didn't finish starting in time.")
                }
            }
        }
    }

    /// An .apk arrived from Finder. Install it — booting the phone first
    /// if needed.
    func handleIncomingAPK(_ url: URL) {
        if activeSerial != nil {
            installAPK(at: url)
            return
        }
        guard let name = selectedAVD ?? avds.first else {
            log("Create a phone first, then open the .apk again.")
            activeApp = .devices
            return
        }
        log("Starting the phone to install \(url.lastPathComponent)…")
        guard EmulatorManager.shared.startAVD(name: name, headless: headlessBoot) else {
            log("Couldn't start the phone — the engine isn't installed yet.")
            return
        }
        Task.detached(priority: .userInitiated) {
            let serial = EmulatorManager.shared.waitForBootedEmulator(timeoutSeconds: 240)
            await MainActor.run {
                if let serial {
                    self.activeSerial = serial
                    self.installAPK(at: url)
                    self.refreshIdentities()
                } else {
                    self.log("The phone didn't finish starting in time.")
                }
            }
        }
    }

    /// Open the embedded screen — but never onto Android's own launcher;
    /// the thin shell IS the launcher. If nothing is open, say so instead.
    func openScreen() {
        guard let serial = activeSerial else { return }
        Task.detached(priority: .userInitiated) {
            let launcher = EmulatorManager.shared.defaultLauncherPackage(serial: serial)
            let foreground = EmulatorManager.shared.foregroundPackage(serial: serial)
            await MainActor.run {
                if let launcher, foreground == launcher {
                    self.log("Nothing is open on the phone — tap an app to start one.")
                } else {
                    withAnimation(.easeIn(duration: 0.15)) { self.activeApp = .screen }
                }
            }
        }
    }

    /// Dock power button: boots the selected phone when everything is off,
    /// shuts everything down when a phone is running.
    func togglePower() {
        if activeSerial != nil {
            log("Shutting down all phones…")
            Task.detached(priority: .userInitiated) {
                let count = EmulatorManager.shared.stopAll()
                await MainActor.run {
                    self.log(count > 0 ? "Stopped \(count) phone(s)." : "No phone is running.")
                    self.refreshIdentities()
                }
            }
        } else if let name = selectedAVD ?? avds.first {
            log("Booting \(name)…")
            if EmulatorManager.shared.startAVD(name: name, headless: headlessBoot) {
                log(headlessBoot
                    ? "Boot started — the phone will live in the Screen view."
                    : "Boot started — your apps will appear once the phone is up.")
            } else {
                log("Boot failed: the engine isn't installed yet — create a device first.")
            }
        } else {
            // Nothing to boot yet — guide to device creation.
            activeApp = .devices
        }
    }

    /// Toggle headed/headless mode and reboot the phone if running.
    func toggleHeadedHeadless() {
        guard let name = resolveTargetDevice(isRunning: activeSerial != nil,
                                             activeDeviceName: activeDeviceName,
                                             selectedAVD: selectedAVD,
                                             avds: avds) else { return }
        let serial = activeSerial
        
        headlessBoot.toggle()
        let targetHeadless = headlessBoot // Capture on the MainActor to prevent isolation compilation error
        
        if serial != nil {
            log("Rebooting [\(name)] in \(targetHeadless ? "embedded" : "windowed") mode...")
            Task.detached(priority: .userInitiated) {
                _ = EmulatorManager.shared.stopAll()
                
                var retries = 0
                while EmulatorManager.shared.connectedEmulators().count > 0 && retries < 20 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    retries += 1
                }
                
                let ok = EmulatorManager.shared.startAVD(name: name, headless: targetHeadless)
                
                await MainActor.run {
                    if ok {
                        self.log(targetHeadless
                            ? "Boot started — the phone will live in the Screen view."
                            : "Boot started — your apps will appear once the phone is up.")
                        if targetHeadless {
                            self.openScreen()
                        } else {
                            self.activeApp = nil
                        }
                    } else {
                        self.log("Failed to reboot the phone.")
                    }
                    self.refreshIdentities()
                }
            }
        } else {
            log("Configured phone boot mode to \(targetHeadless ? "embedded" : "windowed").")
        }
    }

    func launchApp(packageName: String) {
        guard let serial = activeSerial else { return }
        log("Opening \(AppCatalog.displayName(for: packageName)) on \(activeDeviceName)…")
        Task.detached(priority: .userInitiated) {
            let ok = EmulatorManager.shared.launchApp(serial: serial, packageName: packageName)
            if !ok {
                await MainActor.run {
                    self.log("Couldn't open \(AppCatalog.displayName(for: packageName)).")
                }
            }
        }
        // With no separate emulator window, follow the app onto the screen.
        if headlessBoot {
            withAnimation(.easeIn(duration: 0.15)) { activeApp = .screen }
        }
    }

    func installAPK(at url: URL) {
        guard let serial = activeSerial else {
            log("No running phone — launch a virtual device before installing.")
            return
        }
        let apkSize = EmulatorManager.shared.getFileSize(path: url.path)
        let sizeStr = ByteCountFormatter.string(fromByteCount: apkSize, countStyle: .file)
        log("Installing \(url.lastPathComponent) (\(sizeStr))…")
        let headless = headlessBoot
        Task.detached(priority: .userInitiated) {
            let manager = EmulatorManager.shared
            // Snapshot first so the new package can be named afterwards: `adb
            // install` doesn't say what it installed, and reading the name out
            // of the APK would mean shipping aapt for one string.
            let before = Set(manager.listThirdPartyPackages(serial: serial, userId: 0))
            let ok = manager.installAPK(serial: serial, path: url.path) { line, transient in
                Task { @MainActor in
                    self.log("· " + line, transient: transient)
                }
            }
            guard ok else {
                await MainActor.run {
                    self.log("Installation of \(url.lastPathComponent) failed.")
                    self.refreshIdentities()
                }
                return
            }

            // Drop an app in, land in the app. Anything less makes the user go
            // find what they just installed, on a phone whose home screen this
            // app exists to keep them out of.
            let installed = Set(manager.listThirdPartyPackages(serial: serial, userId: 0))
                .subtracting(before)
                .first
            await MainActor.run {
                self.log("\(url.lastPathComponent) installed.")
                self.refreshIdentities()
                if let installed {
                    self.log("Opening \(AppCatalog.displayName(for: installed))…")
                }
            }
            guard let installed else { return }

            let launched = manager.launchUntilForeground(serial: serial, packageName: installed)
            await MainActor.run {
                guard launched else {
                    self.log("\(AppCatalog.displayName(for: installed)) didn't open — tap it to try again.")
                    return
                }
                // Only when the phone has no window of its own; otherwise the
                // app is already on screen in it.
                if headless {
                    withAnimation(.easeIn(duration: 0.15)) { self.activeApp = .screen }
                }
            }
        }
    }

    func cloneApp(packageName: String, toUser userId: Int) {
        guard let serial = activeSerial else { return }
        log("Cloning \(packageName) to identity ID \(userId)...")
        Task.detached(priority: .userInitiated) {
            let ok = EmulatorManager.shared.cloneApp(serial: serial, packageName: packageName, toUser: userId)
            await MainActor.run {
                if ok {
                    self.log("\(packageName) is now enabled for identity \(userId).")
                    self.refreshStorageStats()
                } else {
                    self.log("Failed to clone \(packageName).")
                }
            }
        }
    }
    
    func runCleanUninstall() {
        progressMessage = "Uninstalling components..."
        isCreating = true
        
        let deleteAVDs = uninstallDeleteAVDs
        let removeSdk = uninstallSdk
        let removeJava = uninstallJava
        let removeTemp = uninstallTemp
        
        Task.detached(priority: .userInitiated) {
            let manager = EmulatorManager.shared
            
            await MainActor.run { self.progressMessage = "Stopping all active emulators..." }
            _ = manager.stopAll()
            
            if deleteAVDs {
                await MainActor.run { self.progressMessage = "Purging AVDs and config files..." }
                _ = manager.purgeAVDFiles()
            }
            
            if removeSdk {
                await MainActor.run { self.progressMessage = "Uninstalling Android SDK via Homebrew..." }
                _ = manager.uninstallSdk { line, transient in
                    Task { @MainActor in
                        self.log("· " + line, transient: transient)
                    }
                }
            }
            
            if removeJava {
                await MainActor.run { self.progressMessage = "Uninstalling Java JRE via Homebrew..." }
                _ = manager.uninstallJava { line, transient in
                    Task { @MainActor in
                        self.log("· " + line, transient: transient)
                    }
                }
            }
            
            if removeTemp {
                await MainActor.run { self.progressMessage = "Removing temporary files..." }
                _ = manager.purgeTempFiles()
            }
            
            await MainActor.run {
                self.isCreating = false
                self.selectedAVD = nil
                self.refreshAVDs()
                
                let alert = NSAlert()
                alert.messageText = "Uninstall Complete"
                alert.informativeText = "Selected components have been removed. You can now drag andross.app to the Trash to complete uninstallation."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
    
    // MARK: - AVD Lifecycle
    
    func fixDependencies() {
        progressMessage = "Fixing system dependencies..."
        isCreating = true
        
        Task.detached(priority: .userInitiated) {
            let manager = EmulatorManager.shared
            let status = manager.checkStatus()
            
            if !status.java {
                await MainActor.run { self.progressMessage = "Installing Java (Temurin)..." }
                _ = manager.installJava { line, transient in
                    Task { @MainActor in
                        self.log("· " + line, transient: transient)
                    }
                }
            }
            
            if !status.sdk {
                await MainActor.run { self.progressMessage = "Installing Android SDK command-line tools..." }
                _ = manager.installSdk { line, transient in
                    Task { @MainActor in
                        self.log("· " + line, transient: transient)
                    }
                }
            }
            
            await MainActor.run {
                self.checkDependencies()
                self.isCreating = false
            }
        }
    }
    
    func createNewPhone() {
        guard !newName.isEmpty else { return }
        progressMessage = "Creating virtual device [\(newName)]..."
        isCreating = true
        
        let name = newName
        let typeVal = newType
        let profileVal = newProfile
        let apiVal = newAPILevel

        Task.detached(priority: .userInitiated) {
            let type = EmulatorManager.SystemType(rawValue: typeVal) ?? .googlePlay
            let profile = EmulatorManager.DeviceProfile(rawValue: profileVal) ?? .phonePortrait
            _ = await EmulatorManager.shared.createAVD(name: name, type: type, profile: profile, apiLevel: apiVal) { progress, transient in
                Task { @MainActor in
                    self.log(progress, transient: transient)
                }
            }
            
            await MainActor.run {
                self.isCreating = false
                self.newName = ""
                self.refreshAVDs()
                self.selectedAVD = name
            }
        }
    }
    
    func deleteSelected() {
        guard let name = selectedAVD else { return }
        let alert = NSAlert()
        alert.messageText = "Delete virtual device [\(name)]?"
        alert.informativeText = "This action will permanently erase all data on the virtual phone. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            log("Deleting virtual device [\(name)]...")
            Task.detached(priority: .userInitiated) {
                let res = EmulatorManager.shared.deleteAVD(name: name)
                await MainActor.run {
                    if res.ok {
                        self.log("Successfully deleted device.")
                    } else {
                        self.log("Deletion failed: " + res.stderr)
                    }
                    self.selectedAVD = nil
                    self.refreshAVDs()
                }
            }
        }
    }
}

// Configures the borderless window with a transparent background and makes it draggable
struct WindowConfigurator: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    
    func makeNSView(context: Context) -> NSView {
        let view = ConfiguratorNSView()
        view.targetWidth = width
        view.targetHeight = height
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let configView = nsView as? ConfiguratorNSView {
            configView.updateWindowSize(width: width, height: height)
        }
    }
}

/// The window's entire visible surface (borderless: this view fills the whole
/// window, edge to edge — there is no separate system-drawn chrome to leak from
/// behind it). It hosts the notch (`ChipBarView`) in a strip across the top; the
/// notch owns its own hover now, so this view no longer tracks the pointer — it
/// used to fade a hover strip in and out, back when the controls were bare dots
/// on the glass instead of a self-contained pill.
private class CustomGlassView: NSVisualEffectView {
    /// Height of the top strip the notch host is pinned to — tall enough for the
    /// idle pill and the expanded bar it grows into.
    static let stripHeight: CGFloat = 64
}

/// The hover chip: hand-drawn traffic lights (borderless windows have no
/// real ones — see the Probe 2 note on configureWindow) plus the window
/// controls on the right, rendered directly on the glass, visible only
/// while `chromeHovering`. No pill backdrop: the dots sit straight on the
/// glass, matching the old always-on borderless look, just hover-gated.
/// The home screen's notch — the shared `Island` with the home controls on the
/// right (the screen toggle and pop-out, only while a phone is running). Idle it
/// stands in for the old "andross" wordmark; the phone screen wears the very
/// same pill, so the two screens read as one app.
private struct ChipBarView: View {
    @ObservedObject var model = AppModel.shared

    /// On the phone screen the island collapses to a hoverable notch (so it can
    /// clear Android's own status bar) carrying the phone's keys; at home it
    /// stays a full black bar with the home controls. Both live in this one
    /// top-level host — pinned above the streamed screen's touch layer — which
    /// is the whole reason the buttons and the window-drag get the mouse at all.
    /// When the island was a sibling of that touch NSView down in ScreenView's
    /// SwiftUI tree, the NSView swallowed every click before the island saw it.
    private var onScreen: Bool { model.activeApp == .screen }

    var body: some View {
        Island(alwaysExpanded: !onScreen) {
            if onScreen {
                phoneControls
            } else if model.activeSerial != nil {
                homeControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        // Flush to the window's top edge so the bar reads as the window's own
        // chrome gone black, its corners meeting the 55pt glass rounding.
        .ignoresSafeArea()
    }

    /// Home: open/close the embedded screen, pop the phone window in/out.
    private var homeControls: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if model.activeApp == .screen { model.activeApp = nil }
                    else { model.openScreen() }
                }
            } label: {
                Image(systemName: model.activeApp == .screen ? "iphone.slash" : "play.display")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(model.activeApp == .screen ? Color.androidGreen : Color.white.opacity(0.85))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(model.activeApp == .screen ? "Close Screen View" : "Open Screen View")

            Button { model.toggleHeadedHeadless() } label: {
                Image(systemName: model.headlessBoot ? "arrow.up.right.square" : "arrow.down.left.square")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(model.headlessBoot ? "Pop Out Phone Window" : "Embed Phone Window")
        }
    }

    /// Phone: the ring/silent switch (gain-based mute), Back, Exit, and the
    /// pop-out toggle. Home and Recents stay off — the shell *is* the launcher,
    /// so leaving the screen is the ✕, and the phone's own home bar still swipes.
    private var phoneControls: some View {
        HStack(spacing: 8) {
            Button { model.audioMuted.toggle() } label: {
                Image(systemName: model.audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(model.audioMuted ? Color.slateRed : Color.white.opacity(0.85))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(model.audioMuted ? "Unmute Phone Audio" : "Mute Phone Audio")
            .accessibilityLabel(model.audioMuted ? "Unmute Phone Audio" : "Mute Phone Audio")

            navKey(icon: "chevron.backward", key: .back, label: "Back")

            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.activeApp = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.slateRed)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain).help("Exit Screen").accessibilityLabel("Exit Screen")

            Button { model.toggleHeadedHeadless() } label: {
                Image(systemName: model.headlessBoot ? "arrow.up.right.square" : "arrow.down.left.square")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(model.headlessBoot ? "Pop Out Phone Window" : "Embed Phone Window")
            .accessibilityLabel(model.headlessBoot ? "Pop Out Phone Window" : "Embed Phone Window")
        }
    }

    private func navKey(icon: String, key: EmulatorManager.AndroidKey, label: String) -> some View {
        Button {
            guard let serial = model.activeSerial else { return }
            Task.detached(priority: .userInitiated) {
                _ = EmulatorManager.shared.inputKey(serial: serial, key: key)
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Preset-size list, presented as a popover off the green light — mirrors
/// cubeconjure's LangPicker exactly (plain button + .popover, not SwiftUI's
/// Menu, which collapses its hit area to a point).
///
/// Shared: the green light exists twice now (the chip bar on the home screen,
/// the island over the phone), and a second copy of this list is a second place
/// to forget to add a size to.
struct SizeMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preset Sizes")
                .font(.system(size: 9)).bold()
                .foregroundStyle(Color.slateTextDim)
                .padding(.horizontal, 4)

            Divider().background(Color.white.opacity(0.1))

            Group {
                sizeMenuButton(title: "Phone (Portrait)", isTablet: false, isLandscape: false)
                sizeMenuButton(title: "Phone (Landscape)", isTablet: false, isLandscape: true)
                sizeMenuButton(title: "Tablet (Portrait)", isTablet: true, isLandscape: false)
                sizeMenuButton(title: "Tablet (Landscape)", isTablet: true, isLandscape: true)
            }
        }
        .padding(6)
        .frame(width: 140)
    }

    private func sizeMenuButton(title: String, isTablet: Bool, isLandscape: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                model.isTablet = isTablet
                model.isLandscape = isLandscape
                model.refreshStorageStats()
            }
            model.sizeMenuVisible = false
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(Color.white)
                Spacer()
                if model.isTablet == isTablet && model.isLandscape == isLandscape {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.androidGreen)
                }
            }
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

class ConfiguratorNSView: NSView {
    var targetWidth: CGFloat = 0
    var targetHeight: CGFloat = 0
    private var lastFrame: NSRect? = nil
    private var isFirstResize = true
    private var isProgrammaticMove = false
    private var isPositioningScheduled = false
    private var isConfigured = false
    
    private func log(_ msg: String) {
        NSLog("[Andross] %@", msg)
    }
    
    func updateWindowSize(width: CGFloat, height: CGFloat) {
        self.targetWidth = width
        self.targetHeight = height
        
        guard let window = self.window else {
            log("[WARN] updateWindowSize called but self.window is nil!")
            return
        }
        
        let currentSize = window.frame.size

        if isFirstResize {
            if isPositioningScheduled { return }
            isPositioningScheduled = true

            let remember = UserDefaults.standard.bool(forKey: "rememberWindowPosition")
            let hasSavedX = UserDefaults.standard.object(forKey: "windowLastX") != nil
            let hasSavedTopY = UserDefaults.standard.object(forKey: "windowLastTopY") != nil

            var newFrame: NSRect
            if remember && hasSavedX && hasSavedTopY {
                let savedX = UserDefaults.standard.double(forKey: "windowLastX")
                let savedTopY = UserDefaults.standard.double(forKey: "windowLastTopY")
                let newY = savedTopY - height
                let restored = NSRect(x: CGFloat(savedX), y: CGFloat(newY), width: width, height: height)
                // Guard against a saved position that now lands off-screen
                // (display unplugged / resolution change) — otherwise the
                // window restores somewhere the user can't reach it.
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
                newFrame = clampedWindowFrame(restored, visibleFrame: visible)
            } else {
                let screen = window.screen ?? NSScreen.main
                let screenFrame = screen?.visibleFrame ?? .zero
                let newX = screenFrame.origin.x + (screenFrame.size.width - width) / 2
                let newY = screenFrame.origin.y + (screenFrame.size.height - height) / 2
                newFrame = NSRect(x: newX, y: newY, width: width, height: height)
            }
            
            self.lastFrame = newFrame
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let window = self.window else { return }
                self.isProgrammaticMove = true
                window.setFrame(newFrame, display: true, animate: false)
                self.lastFrame = newFrame
                
                // Smoothly fade in the window once it's correctly resized and positioned.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    window.animator().alphaValue = 1.0
                }
                
                // Delay disabling first resize protection to allow startup layout passes to settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.isFirstResize = false
                }
                
                DispatchQueue.main.async { [weak self] in
                    self?.isProgrammaticMove = false
                }
            }
            return
        }
        
        if currentSize.width != width || currentSize.height != height {
            let oldFrame = window.frame
            // Lock top-left corner during size changes!
            let newY = oldFrame.origin.y + (oldFrame.size.height - height)
            let newFrame = NSRect(x: oldFrame.origin.x, y: newY, width: width, height: height)

            self.lastFrame = newFrame
            self.isProgrammaticMove = true
            window.setFrame(newFrame, display: true, animate: false)
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammaticMove = false
            }
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }
        
        if isConfigured { return }
        isConfigured = true
        
        configureWindow(initial: true)
        
        // Register notifications and store initial frame
        self.lastFrame = window.frame
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidMove),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidResize),
            name: NSWindow.didResizeNotification,
            object: window
        )
        
        // Ensure positioning and size are updated immediately when the window is available
        updateWindowSize(width: targetWidth, height: targetHeight)

        // 2. Intercept and wrap the window content view in our CustomGlassView.
        //    Borderless: the glass IS the content view (no separate strip
        //    container needed — there's no system title bar height to
        //    reserve space for). Every visible pixel in the window is this
        //    view or something drawn inside it.
        guard let originalContentView = window.contentView,
              !(originalContentView is CustomGlassView) else {
            return
        }

        let glassView = CustomGlassView()
        glassView.material = .hudWindow // Dark elegant frosted glass blur
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        glassView.wantsLayer = true

        // Apply maskImage for perfect rounding of the visual effect material
        let radius: CGFloat = 55
        let maskSize = NSSize(width: radius * 2, height: radius * 2)
        let maskImg = NSImage(size: maskSize, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        maskImg.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        maskImg.resizingMode = .stretch
        glassView.maskImage = maskImg

        glassView.layer?.cornerRadius = radius
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.masksToBounds = true
        glassView.layer?.borderWidth = 1.5
        glassView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor

        // Swap content view
        window.contentView = glassView

        // Add original content view as subview of glass view
        glassView.addSubview(originalContentView)
        originalContentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            originalContentView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            originalContentView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            originalContentView.topAnchor.constraint(equalTo: glassView.topAnchor),
            originalContentView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
        ])

        // Chip bar (traffic lights + window controls), overlaid on the top
        // strip of the glass — on top of the regular SwiftUI content,
        // exactly where the old hand-drawn dots used to sit.
        let chipHost = NSHostingView(rootView: ChipBarView())
        chipHost.sizingOptions = []
        glassView.addSubview(chipHost)
        chipHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chipHost.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            chipHost.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            chipHost.topAnchor.constraint(equalTo: glassView.topAnchor),
            chipHost.heightAnchor.constraint(equalToConstant: CustomGlassView.stripHeight)
        ])

        // Hide standard window background visual effect views (siblings of content view under NSThemeFrame)
        if let rootView = glassView.superview {
            for subview in rootView.subviews {
                if subview !== glassView {
                    let className = String(describing: type(of: subview))
                    if subview is NSVisualEffectView || className.contains("VisualEffectView") {
                        subview.isHidden = true
                        subview.alphaValue = 0.0
                    }
                }
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleWindowDidResize(_ notification: Notification) {
        guard let window = self.window,
              let lastFrame = self.lastFrame else { return }
        
        let newFrame = window.frame
        if isFirstResize {
            self.lastFrame = newFrame
            return
        }
        
        if newFrame.size != lastFrame.size {
            let oldTopLeftY = lastFrame.origin.y + lastFrame.size.height
            let adjustedY = oldTopLeftY - newFrame.size.height
            let adjustedFrame = NSRect(
                x: lastFrame.origin.x,
                y: adjustedY,
                width: newFrame.size.width,
                height: newFrame.size.height
            )
            self.lastFrame = adjustedFrame
            window.setFrame(adjustedFrame, display: true, animate: false)
        } else {
            self.lastFrame = newFrame
        }
        saveWindowPositionIfNeeded()
    }
    
    @objc private func handleWindowDidMove(_ notification: Notification) {
        if let window = self.window {
            self.lastFrame = window.frame
            saveWindowPositionIfNeeded()
        }
    }
    
    private func saveWindowPositionIfNeeded() {
        guard let window = self.window, !isFirstResize, !isProgrammaticMove else { return }
        guard UserDefaults.standard.bool(forKey: "rememberWindowPosition") else { return }
        let frame = window.frame
        let topY = frame.origin.y + frame.size.height
        UserDefaults.standard.set(Double(frame.origin.x), forKey: "windowLastX")
        UserDefaults.standard.set(Double(topY), forKey: "windowLastTopY")
    }

    override func layout() {
        super.layout()
        configureWindow(initial: false)
        clearBackgrounds()
    }
    
    override func updateLayer() {
        super.updateLayer()
        configureWindow(initial: false)
        clearBackgrounds()
    }
    
    private func clearBackgrounds() {
        guard let window = self.window,
              let rootView = window.contentView?.superview else { return }
        
        let contentView = window.contentView
        
        // Ensure the window background properties are always clear
        window.backgroundColor = .clear
        window.isOpaque = false
        
        // 1. Hide the window's own native visual effect views (siblings of contentView under rootView)
        for subview in rootView.subviews {
            if subview !== contentView {
                let className = String(describing: type(of: subview))
                if subview is NSVisualEffectView || className.contains("VisualEffectView") {
                    subview.isHidden = true
                    subview.alphaValue = 0.0
                }
            }
        }
        
        // 2. Clear background layers of other non-material layout views inside contentView
        func clearContainers(_ view: NSView) {
            let className = String(describing: type(of: view))
            let isVisualEffect = view is NSVisualEffectView || className.contains("VisualEffectView")
            
            if !isVisualEffect && view !== rootView && view !== contentView {
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
            
            for subview in view.subviews {
                clearContainers(subview)
            }
        }
        
        if let contentView = contentView {
            clearContainers(contentView)
        }
        
        window.invalidateShadow()
    }
    
    private func configureWindow(initial: Bool) {
        guard let window = self.window else { return }
        // The island's window controls need this exact window — the same reason
        // the chip bar captures it rather than reaching for NSApp.keyWindow,
        // which is nil here anyway (a borderless window never becomes key).
        AppModel.shared.mainWindow = window
        if initial {
            // Borderless: the window contributes zero system-drawn pixels
            // (no NSThemeFrame chrome, no macOS 26 glass backplate), so
            // there's nothing for our own rounded glass content to leak
            // out from underneath. .miniaturizable/.closable still let
            // window.miniaturize(_:)/performClose(_:) work correctly even
            // without .titled — verified directly (AXMinimized flips true).
            // Real standardWindowButton(_:for:) factory widgets were tried
            // first and rejected: outside their real titlebar slot they
            // render as plain black dots and don't respond to clicks (even
            // AX-driven presses) — dead weight pretending to be chrome.
            // Hand-drawn dots + explicit actions are what actually work.
            window.styleMask = [.borderless, .resizable, .miniaturizable, .closable]
            // The app is hard dark-themed (preferredColorScheme(.dark)); pin
            // the window appearance so AppKit-side chrome — the glass
            // material — renders dark too.
            window.appearance = NSAppearance(named: .darkAqua)
            window.collectionBehavior = [.managed]
            window.isMovableByWindowBackground = true
            window.hasShadow = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isRestorable = false
            window.identifier = nil
            window.restorationClass = nil
            window.alphaValue = 0.0 // Hide window initially to prevent flickering/visual flash
            window.center() // Center on screen on first load
        }
        
        window.backgroundColor = .clear
        window.isOpaque = false
        window.invalidateShadow()
    }
}

struct ContentView: View {
    // The shared instance — the app delegate routes Finder-opened APKs here.
    @StateObject private var model = AppModel.shared
    @State private var showCreateSheet = false
    @State private var dockHovering = false
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Desktop Content Area
                VStack(spacing: 0) {
                    // A band of top chrome that leaves room for the notch pill
                    // (ChipBarView) riding above it. On the home screen it holds
                    // nothing — the notch is the wordmark now — and a sub-view
                    // shows its own title. No divider: the notch is the whole of
                    // the top edge's identity, and a line under it just fenced
                    // off empty space. The embedded screen skips the band
                    // entirely; every point here is a point it would shrink by.
                    if model.activeApp != .screen {
                        HStack {
                            Spacer()
                            if let activeApp = model.activeApp {
                                Text(activeAppTitle(activeApp))
                                    .font(.headline).bold()
                                    .foregroundStyle(Color.white)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 36)
                        .padding(.top, 32)
                        .padding(.bottom, 12)
                        .background(Color.clear)
                    }

                    // Main Content Canvas
                    if let activeApp = model.activeApp {
                        if activeApp == .screen {
                            // The embedded screen handles its own gestures —
                            // no ScrollView, it would swallow drags.
                            ScreenAppView(model: model)
                        } else {
                            ScrollView {
                                appContentView(activeApp)
                                    .padding(16)
                            }
                            .background(Color.clear)
                        }
                    } else {
                        // Home: the user's own Android apps, like a real phone.
                        // Tiles persist while the phone is off — tapping one
                        // boots it and launches the app.
                        VStack(spacing: 0) {
                            if model.activeSerial != nil {
                                // Status chip: which phone / which identity,
                                // plus the door into the embedded screen.
                                let identityName = model.identities.first { $0.userId == model.activeIdentityId }?.name ?? "Owner"
                                Button {
                                    model.openScreen()
                                } label: {
                                    HStack(spacing: 5) {
                                        Text("\(model.activeDeviceName) · \(identityName)")
                                        Image(systemName: "play.display")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Color.androidGreen)
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(Color.slateTextDim)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.05))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Open the phone's screen here")
                                .accessibilityLabel("Open Screen")
                                .padding(.top, 8)
                            } else if !model.homePackages.isEmpty {
                                Text(model.pendingLaunch != nil ? "Starting the phone…" : "Phone is off — tap an app to start it.")
                                    .font(.caption2)
                                    .foregroundStyle(Color.slateTextDim)
                                    .padding(.top, 12)
                            }

                            if model.homePackages.isEmpty {
                                Spacer()
                                VStack(spacing: 10) {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 28))
                                        .foregroundStyle(Color.slateTextDim)
                                    Text("No apps yet.")
                                        .font(.caption)
                                        .foregroundStyle(Color.slateTextDim)
                                    Text("Drop an .apk file anywhere in this window —\nandross takes care of the rest.")
                                        .font(.system(size: 10))
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(Color.slateTextDim.opacity(0.8))
                                }
                                Spacer()
                            } else {
                                ScrollView {
                                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(86), spacing: 18), count: model.isLandscape ? 6 : 3), spacing: 20) {
                                        ForEach(model.homePackages, id: \.self) { pkg in
                                            androidAppIcon(packageName: pkg,
                                                           dimmed: model.activeSerial == nil,
                                                           busy: model.pendingLaunch == pkg) {
                                                if model.activeSerial != nil {
                                                    model.launchApp(packageName: pkg)
                                                } else {
                                                    model.bootAndLaunch(packageName: pkg)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.top, 18)
                                }
                            }

                            // Dock: power + the three system surfaces.
                            // Labels stay hidden until the pointer enters the dock.
                            HStack(spacing: model.isLandscape ? 40 : 16) {
                                dockIcon(title: model.activeSerial != nil ? "Power Off" : "Power On",
                                         icon: "power",
                                         tint: model.activeSerial != nil ? .androidGreen : .slateTextDim,
                                         showLabel: dockHovering) {
                                    model.togglePower()
                                }
                                dockIcon(title: "Devices", icon: "iphone", showLabel: dockHovering) {
                                    withAnimation(.easeIn(duration: 0.15)) { model.activeApp = .devices }
                                }
                                dockIcon(title: "Sandboxes", icon: "person.2", showLabel: dockHovering) {
                                    withAnimation(.easeIn(duration: 0.15)) { model.activeApp = .sandboxes }
                                }
                                dockIcon(title: "Settings", icon: "gearshape", showLabel: dockHovering) {
                                    withAnimation(.easeIn(duration: 0.15)) { model.activeApp = .settings }
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)
                            .liquidGlassBackground(cornerRadius: 30)
                            .padding(.bottom, 20)
                            .padding(.top, 6)
                            .onHover { hovering in
                                withAnimation(.easeOut(duration: 0.16)) {
                                    dockHovering = hovering
                                }
                            }
                        }
                        .background(Color.clear)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Bottom Android Gesture Navigation Bar Pill — a real Button so
                // it always wins hit-testing against window-background dragging.
                // Skipped for the embedded screen: the phone streams its own
                // gesture bar, so ours would be a second one stacked under it,
                // and the screen's floating pill already carries Back/Home/Exit.
                if model.activeApp != nil && model.activeApp != .screen {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            model.activeApp = nil
                        }
                    } label: {
                        Capsule()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 80, height: 4)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Home")
                    .help("Back to home screen")
                }
            }
            .frame(width: model.currentWidth, height: model.currentHeight)
            .background(Color.slateDeep.opacity(0.2))
            .background(WindowConfigurator(width: model.currentWidth, height: model.currentHeight)) // Apply NSWindow configurations
            
            // Overlay 2: Progress indicators for background tasks
            if model.isCreating {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text(model.progressMessage)
                        .font(.subheadline).bold()
                        .foregroundStyle(Color.androidGreen)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.logs, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Color.slateTextDim)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: model.currentHeight > 450 ? 120 : 70)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 24)
                }
                .frame(width: model.currentWidth, height: model.currentHeight)
                .background(.ultraThinMaterial)
                .background(Color.black.opacity(0.65))
            }
        }
        // The whole window is an APK drop target, on every screen.
        .onDrop(of: [.fileURL], isTargeted: $model.isDragging) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    if let url, url.pathExtension.lowercased() == "apk" {
                        model.installAPK(at: url)
                    } else {
                        model.log("That file isn't an Android .apk package.")
                    }
                }
            }
            return true
        }
        .overlay {
            if model.isDragging {
                VStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.androidGreen)
                    Text("Drop to install")
                        .font(.subheadline).bold()
                        .foregroundStyle(Color.androidGreen)
                }
                .frame(width: model.currentWidth - 24, height: model.currentHeight - 24)
                .background(Color.slateDeep.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 44, style: .continuous)
                        .stroke(Color.androidGreen, style: StrokeStyle(lineWidth: 2, dash: [6]))
                )
                .allowsHitTesting(false)
            }
        }
        // Create Device Sheet
        .sheet(isPresented: $showCreateSheet) {
            VStack(spacing: 16) {
                Text("Create New Virtual Phone").font(.headline)
                
                TextField("Device name (e.g. line-creator)", text: $model.newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                
                Picker("System", selection: $model.newType) {
                    Text("Google Play — Play Store built in").tag(1)
                    Text("Open source — apps via Aurora Store").tag(2)
                    Text("Blank — install apps yourself").tag(3)
                }
                .frame(width: 260)

                Picker("Size", selection: $model.newProfile) {
                    Text("Phone (Portrait)").tag(1)
                    Text("Phone (Landscape)").tag(2)
                    Text("Tablet (Portrait)").tag(3)
                    Text("Tablet (Landscape)").tag(4)
                }
                .frame(width: 260)

                Picker("Android", selection: $model.newAPILevel) {
                    ForEach(EmulatorManager.supportedAPILevels, id: \.self) { level in
                        Text(AppCatalog.androidVersionName(apiLevel: level)).tag(level)
                    }
                }
                .frame(width: 260)
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        showCreateSheet = false
                        model.newName = ""
                    }
                    .buttonStyle(.borderless)
                    
                    Button("Create") {
                        showCreateSheet = false
                        model.createNewPhone()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.androidGreen)
                    .disabled(model.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 300)
        }
        .background(Color.clear)
    }
    
    private func activeAppTitle(_ app: AppModel.ActiveApp) -> String {
        switch app {
        case .devices: return "Devices"
        case .sandboxes: return "Sandboxes"
        case .settings: return "Settings"
        case .screen: return model.activeDeviceName.isEmpty ? "Screen" : model.activeDeviceName
        }
    }
    
    @ViewBuilder
    private func appContentView(_ app: AppModel.ActiveApp) -> some View {
        switch app {
        case .devices:
            DevicesAppView(model: model, showCreateSheet: $showCreateSheet)
        case .sandboxes:
            SandboxesAppView(model: model)
        case .settings:
            SettingsAppView(model: model)
        case .screen:
            ScreenAppView(model: model)
        }
    }
    
    /// Dock icon. Labels are hidden until the pointer hovers over the dock.
    private func dockIcon(title: String, icon: String, tint: Color = .androidGreen,
                          showLabel: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(tint)
                    .frame(width: 58, height: 58)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if showLabel {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private static let avatarPalette: [Color] = [
        Color(hex: 0x3DDC84), Color(hex: 0x37B9C5), Color(hex: 0x5E9CF2),
        Color(hex: 0xB387F0), Color(hex: 0xE8A06A), Color(hex: 0xE87C9A),
    ]

    /// Home-screen icon for an installed Android app: letter avatar tile
    /// (we can't cheaply extract real icons from APKs) + display name.
    /// `dimmed` marks tiles shown while the phone is off; `busy` shows the
    /// boot-in-progress spinner.
    private func androidAppIcon(packageName: String, dimmed: Bool = false, busy: Bool = false,
                                action: @escaping () -> Void) -> some View {
        let name = AppCatalog.displayName(for: packageName)
        let color = Self.avatarPalette[abs(packageName.hashValue) % Self.avatarPalette.count]
        return Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.slateDeep)
                        .frame(width: 58, height: 58)
                        .background(
                            LinearGradient(colors: [color, color.opacity(0.72)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(dimmed && !busy ? 0.55 : 1)

                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color.white.opacity(dimmed && !busy ? 0.6 : 0.9))
                    .frame(maxWidth: 82)
            }
        }
        .buttonStyle(.plain)
        .help(packageName)
        .accessibilityLabel(name)
    }
}

// APP VIEW 1: Devices app
struct DevicesAppView: View {
    @ObservedObject var model: AppModel
    @Binding var showCreateSheet: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Your Virtual Phones")
                    .font(.subheadline).bold()
                Spacer()
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .tint(.androidGreen)
                .controlSize(.small)
            }
            
            if model.avds.isEmpty {
                VStack(spacing: 8) {
                    Text("No virtual phones yet.")
                        .font(.caption)
                        .foregroundStyle(Color.slateTextDim)
                    Text("Click Add to create your first one — andross fetches everything it needs.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.slateTextDim)
                }
                .padding(.vertical, 30)
            } else {
                ForEach(model.avds, id: \.self) { name in
                    let isRunning = model.runningAVDNames.contains(name)
                    HStack {
                        Image(systemName: "iphone")
                            .foregroundStyle(isRunning ? Color.androidGreen : Color.slateTextDim)
                        Text(name)
                            .font(.body)
                        Spacer()

                        if isRunning {
                            Text("Running")
                                .font(.caption2).bold()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.androidGreen.opacity(0.2))
                                .foregroundStyle(Color.androidGreen)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            // Launch button
                            Button {
                                model.selectedAVD = name
                                model.log("Booting virtual device [\(name)]...")
                                let ok = EmulatorManager.shared.startAVD(name: name, headless: model.headlessBoot)
                                if ok {
                                    model.log(model.headlessBoot
                                        ? "Boot started — the phone will live in the Screen view."
                                        : "Boot started — the phone window will appear shortly.")
                                    Task {
                                        // Pick up the new device once it registers with adb.
                                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                                        model.refreshIdentities()
                                    }
                                } else {
                                    model.log("Boot failed: emulator engine not installed yet (create a device first to download it).")
                                }
                            } label: {
                                Text("Launch")
                                    .font(.caption).bold()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        // Delete button
                        Button {
                            model.selectedAVD = name
                            model.deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.slateRed)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunning)
                    }
                    .padding(10)
                    .liquidGlassBackground(cornerRadius: 8, customBorderColor: isRunning ? Color.androidGreen.opacity(0.4) : Color.white.opacity(0.1))
                }
            }
        }
    }
}

// APP VIEW 2: Sandboxes app
struct SandboxesAppView: View {
    @ObservedObject var model: AppModel
    @State private var newIdentityName = ""
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Identity Sandboxes")
                    .font(.subheadline).bold()
                Spacer()
                Button {
                    model.refreshIdentities()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            
            if model.identities.isEmpty {
                Text("Identities live inside a running phone.\nLaunch one from Devices first.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.slateTextDim)
                    .padding(.vertical, 30)
            } else {
                ForEach(model.identities) { user in
                    HStack {
                        Image(systemName: user.userId == model.activeIdentityId ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
                            .font(.title2)
                            .foregroundStyle(user.userId == model.activeIdentityId ? Color.androidGreen : Color.slateTextDim)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name)
                                .font(.body).bold()
                                .foregroundStyle(user.userId == model.activeIdentityId ? Color.white : Color.slateTextDim)
                            Text("User ID: \(user.userId)")
                                .font(.caption2)
                                .foregroundStyle(Color.slateTextDim)
                        }
                        
                        Spacer()

                        // Clone an owner-installed app into this identity
                        if !model.ownerPackages.isEmpty && user.userId != 0 {
                            Menu {
                                ForEach(model.ownerPackages, id: \.self) { pkg in
                                    Button(AppCatalog.displayName(for: pkg)) {
                                        model.cloneApp(packageName: pkg, toUser: user.userId)
                                    }
                                }
                            } label: {
                                Image(systemName: "plus.square.on.square")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Add an installed app to this identity")
                        }

                        if user.userId == model.activeIdentityId {
                            Text("Active")
                                .font(.caption2).bold()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.androidGreen.opacity(0.2))
                                .foregroundStyle(Color.androidGreen)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Button("Switch") {
                                model.switchIdentity(id: user.userId)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if user.userId != 0 {
                                Button {
                                    model.deleteIdentity(id: user.userId)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(Color.slateRed)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(8)
                    .liquidGlassBackground(cornerRadius: 6, customBorderColor: user.userId == model.activeIdentityId ? Color.androidGreen.opacity(0.4) : Color.white.opacity(0.1))
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                // Add identity inline form
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add New Identity")
                        .font(.caption).bold()
                    HStack(spacing: 8) {
                        TextField("Name (e.g. work, creator)", text: $newIdentityName)
                            .textFieldStyle(.roundedBorder)
                        
                        Button {
                            model.createIdentity(name: newIdentityName)
                            newIdentityName = ""
                        } label: {
                            Text("Add")
                                .bold()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.androidGreen)
                        .disabled(newIdentityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}

// APP VIEW 6: Settings app
struct SettingsAppView: View {
    @ObservedObject var model: AppModel
    
    var body: some View {
        VStack(spacing: 20) {
            // Section 1: System Status
            VStack(alignment: .leading, spacing: 12) {
                Text("System Status")
                    .font(.caption).bold()
                    .foregroundStyle(Color.white)

                VStack(spacing: 8) {
                    dependencyRow(name: "Java runtime", active: model.depStatus.java)
                    dependencyRow(name: "Android engine", active: model.depStatus.sdk)
                    dependencyRow(name: "Homebrew", active: model.depStatus.brew)
                }
                .padding(10)
                .liquidGlassBackground(cornerRadius: 8, customBorderColor: Color.white.opacity(0.1))

                if !model.depStatus.java || !model.depStatus.sdk {
                    if model.depStatus.brew {
                        Button {
                            model.fixDependencies()
                        } label: {
                            HStack {
                                Spacer()
                                Label("Install Missing Components", systemImage: "wrench.and.screwdriver.fill")
                                    .font(.caption).bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.androidGreen)
                        .controlSize(.small)
                    } else {
                        Text("Homebrew is needed to install the missing components — see brew.sh.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.slateRed)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }
            }

            // Section 2: Storage
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Storage")
                        .font(.caption).bold()
                        .foregroundStyle(Color.white)
                    Spacer()
                    Button {
                        model.refreshStorageStats()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh storage")
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("andross app")
                        Spacer()
                        Text(model.hostAppSize.isEmpty ? "…" : model.hostAppSize).foregroundStyle(Color.white)
                    }
                    HStack {
                        Text("Virtual phones (~/.android)")
                        Spacer()
                        Text(model.hostAvdSize.isEmpty ? "…" : model.hostAvdSize).foregroundStyle(Color.white)
                    }
                    HStack {
                        Text("Temporary files (~/.andross_tmp)")
                        Spacer()
                        Text(model.hostTempSize.isEmpty ? "…" : model.hostTempSize).foregroundStyle(Color.white)
                    }

                    if !model.appStorageStats.isEmpty {
                        Divider().background(Color.white.opacity(0.1))
                        ForEach(model.appStorageStats, id: \.packageName) { app in
                            HStack {
                                Text(AppCatalog.displayName(for: app.packageName))
                                    .foregroundStyle(Color.androidGreen)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: app.totalKnownSize, countStyle: .file))
                                    .foregroundStyle(Color.white)
                            }
                            .help(app.packageName)
                        }
                        if model.appStorageStats.contains(where: { $0.dataSize == nil }) {
                            Text("App data sizes aren't readable on Google Play system images.")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.slateTextDim.opacity(0.7))
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color.slateTextDim)
                .padding(10)
                .liquidGlassBackground(cornerRadius: 8, customBorderColor: Color.white.opacity(0.1))
            }

            // Section 3: Recent activity
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent Activity")
                        .font(.caption).bold()
                        .foregroundStyle(Color.white)
                    Spacer()
                    if !model.logs.isEmpty {
                        Button("Clear") { model.clearLogs() }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(Color.slateTextDim)
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if model.logs.isEmpty {
                            Text("Nothing here yet — phone and app actions will appear as they happen.")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.slateTextDim)
                        } else {
                            ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.85))
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
                .liquidGlassBackground(cornerRadius: 8, customBorderColor: Color.white.opacity(0.1))
            }

            // Section 4: Phones
            VStack(alignment: .leading, spacing: 8) {
                Text("Phones")
                    .font(.caption).bold()
                    .foregroundStyle(Color.white)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Keep the phone inside this window", isOn: $model.headlessBoot)
                        .font(.caption2)
                        .foregroundStyle(Color.slateTextDim)
                        .toggleStyle(.checkbox)
                    Text("Beta — boots without a separate emulator window; the phone lives in the Screen view (a few frames per second).")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.slateTextDim.opacity(0.7))
                        .padding(.bottom, 4)

                    Toggle("Remember window position", isOn: $model.rememberWindowPosition)
                        .font(.caption2)
                        .foregroundStyle(Color.slateTextDim)
                        .toggleStyle(.checkbox)
                    Text("Save and restore where you last dragged the window on your screen.")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.slateTextDim.opacity(0.7))
                }
                .padding(10)
                .liquidGlassBackground(cornerRadius: 8, customBorderColor: Color.white.opacity(0.1))

                Button(role: .destructive) {
                    model.log("Shutting down all phones…")
                    Task.detached(priority: .userInitiated) {
                        let count = EmulatorManager.shared.stopAll()
                        await MainActor.run {
                            model.log(count > 0 ? "Stopped \(count) phone(s)." : "No phone is running.")
                            model.refreshIdentities()
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("Shut Down All Phones", systemImage: "stop.circle.fill")
                            .font(.caption).bold()
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .tint(.slateRed)
                .controlSize(.small)
            }

            // Section 5: Clean uninstall
            VStack(alignment: .leading, spacing: 10) {
                Text("Uninstall")
                    .font(.caption).bold()
                    .foregroundStyle(Color.white)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Delete all virtual phones and their data (~/.android)", isOn: $model.uninstallDeleteAVDs)
                    Toggle("Remove the Android engine (Homebrew)", isOn: $model.uninstallSdk)
                    Toggle("Remove the Java runtime (Homebrew)", isOn: $model.uninstallJava)
                    Toggle("Delete temporary files (~/.andross_tmp)", isOn: $model.uninstallTemp)
                }
                .font(.caption2)
                .foregroundStyle(Color.slateTextDim)
                .toggleStyle(.checkbox)
                .padding(10)
                .liquidGlassBackground(cornerRadius: 8, customBorderColor: Color.white.opacity(0.1))
                
                Button(role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "Clean Uninstall andross?"
                    alert.informativeText = "This action will permanently delete/purge the selected components from your Mac. This cannot be undone."
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "Uninstall & Purge")
                    alert.addButton(withTitle: "Cancel")
                    
                    if alert.runModal() == .alertFirstButtonReturn {
                        model.runCleanUninstall()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("Uninstall and Clean Up…", systemImage: "trash.fill")
                            .font(.caption).bold()
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.slateRed)
                .controlSize(.small)
            }
        }
    }
    
    private func dependencyRow(name: String, active: Bool) -> some View {
        HStack {
            Image(systemName: active ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(active ? Color.androidGreen : Color.slateRed)
            Text(name)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.9))
            Spacer()
            Text(active ? "Ready" : "Not installed")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? Color.androidGreen : Color.slateRed)
        }
    }
}
