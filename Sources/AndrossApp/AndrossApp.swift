import SwiftUI
import AppKit
import AndrossCore
import UniformTypeIdentifiers

// Extend Color to support hex colors and Android Green theme
extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double((hex >> 0) & 0xff) / 255,
            opacity: alpha
        )
    }
    
    static let androidGreen = Color(hex: 0x3DDC84)
    static let slateDeep = Color(hex: 0x12171A)
    static let slateGround = Color(hex: 0x1A2225)
    static let slateBorder = Color(hex: 0x2A353A)
    static let slateTextDim = Color(hex: 0x8C9C9E)
    static let slateRed = Color(hex: 0xFF5F56)
}

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

@main
struct AndrossApp: App {
    var body: some Scene {
        WindowGroup("andross") {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(.androidGreen)
                .background(Color.clear)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

// GUI State Control Model
@MainActor
final class AppModel: ObservableObject {
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
    
    // Storage statistics
    @Published var hostAppSize = ""
    @Published var hostAvdSize = ""
    @Published var hostTempSize = ""
    @Published var appStorageStats: [EmulatorManager.AppStorageStats] = []
    
    // Variables for creating new phones and identities
    @Published var newName = ""
    @Published var newType = 1 // 1: Play Store, 2: AOSP+Aurora, 3: Blank AOSP
    @Published var newProfile = 1 // 1: Phone Portrait, 2: Phone Landscape, 3: Tablet Portrait, 4: Tablet Landscape
    
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
    }
    
    @Published var activeApp: ActiveApp? = nil
    
    // Default to Phone Portrait on launch
    @Published var isTablet = false
    @Published var isLandscape = false
    
    var currentWidth: CGFloat {
        if isTablet {
            return isLandscape ? 800 : 500
        } else {
            return isLandscape ? 800 : 360
        }
    }
    
    var currentHeight: CGFloat {
        if isTablet {
            return isLandscape ? 500 : 800
        } else {
            return isLandscape ? 360 : 800
        }
    }
    
    private var lastLineIsTransient = false
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
        if transient {
            if lastLineIsTransient && !logs.isEmpty {
                logs[logs.count - 1] = message
            } else {
                logs.append(message)
                lastLineIsTransient = true
            }
        } else {
            if lastLineIsTransient && !logs.isEmpty {
                logs[logs.count - 1] = message
                lastLineIsTransient = false
            } else {
                logs.append(message)
                lastLineIsTransient = false
            }
        }
        
        // Keep logs capped to avoid excessive memory usage
        if logs.count > 100 {
            logs.removeFirst()
        }
    }
    
    func clearLogs() {
        logs.removeAll()
        lastLineIsTransient = false
    }
    
    func refreshStorageStats() {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let home = NSHomeDirectory()
            
            // 1. Get andross app size (estimate or actual bundle size)
            var appSize: Int64 = 0
            let appPath = home + "/Applications/andross.app"
            if fm.fileExists(atPath: appPath) {
                appSize = EmulatorManager.shared.getDirectorySize(path: appPath)
            } else {
                let bundlePath = Bundle.main.bundlePath
                appSize = EmulatorManager.shared.getDirectorySize(path: bundlePath)
            }
            
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
    }

    func installAPK(at url: URL) {
        guard let serial = activeSerial else {
            log("No running phone — launch a virtual device before installing.")
            return
        }
        let apkSize = EmulatorManager.shared.getFileSize(path: url.path)
        let sizeStr = ByteCountFormatter.string(fromByteCount: apkSize, countStyle: .file)
        log("Installing \(url.lastPathComponent) (\(sizeStr))…")
        Task.detached(priority: .userInitiated) {
            let ok = EmulatorManager.shared.installAPK(serial: serial, path: url.path) { line, transient in
                Task { @MainActor in
                    self.log("· " + line, transient: transient)
                }
            }
            await MainActor.run {
                self.log(ok ? "\(url.lastPathComponent) installed." : "Installation of \(url.lastPathComponent) failed.")
                self.refreshIdentities()
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
        
        Task.detached(priority: .userInitiated) {
            let type = EmulatorManager.SystemType(rawValue: typeVal) ?? .googlePlay
            let profile = EmulatorManager.DeviceProfile(rawValue: profileVal) ?? .phonePortrait
            _ = await EmulatorManager.shared.createAVD(name: name, type: type, profile: profile) { progress, transient in
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

private class CustomGlassView: NSVisualEffectView {
    // Marker class to prevent multiple wrapping
}

class ConfiguratorNSView: NSView, NSWindowDelegate {
    var targetWidth: CGFloat = 0
    var targetHeight: CGFloat = 0
    private var lastFrame: NSRect? = nil
    private var isMaximizedMode = false
    private var savedWindowFrame: NSRect? = nil
    
    func updateWindowSize(width: CGFloat, height: CGFloat) {
        self.targetWidth = width
        self.targetHeight = height
        
        guard let window = self.window else { return }
        
        // Avoid overriding window size if window is currently maximized
        if isMaximizedMode {
            return
        }
        
        // Lock top-left corner during size changes!
        let currentSize = window.frame.size
        if currentSize.width != width || currentSize.height != height {
            let oldFrame = window.frame
            let newY = oldFrame.origin.y + (oldFrame.size.height - height)
            let newFrame = NSRect(x: oldFrame.origin.x, y: newY, width: width, height: height)
            self.lastFrame = newFrame
            window.setFrame(newFrame, display: true, animate: false)
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow(initial: true)
        
        guard let window = self.window else { return }
        
        // Register delegate and store initial frame
        window.delegate = self
        self.lastFrame = window.frame
        
        // Listen to custom maximize toggle notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleMaximize),
            name: NSNotification.Name("ToggleMaximize"),
            object: nil
        )
        
        // 2. Intercept and wrap the window content view in our CustomGlassView
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
    
    // Delegate: Observe size changes to lock top-left corner
    func windowDidResize(_ notification: Notification) {
        guard let window = self.window,
              let lastFrame = self.lastFrame else { return }
        
        let newFrame = window.frame
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
    }
    
    // Delegate: Observe moves to update coordinates
    func windowDidMove(_ notification: Notification) {
        if let window = self.window {
            self.lastFrame = window.frame
        }
    }
    
    @objc private func handleToggleMaximize() {
        self.toggleMaximize()
    }
    
    private func toggleMaximize() {
        guard let window = self.window,
              let screen = window.screen ?? NSScreen.main else { return }
        
        isMaximizedMode.toggle()
        
        if isMaximizedMode {
            // Save current frame
            savedWindowFrame = window.frame
            
            let screenFrame = screen.visibleFrame
            
            // Disable rounding & borders
            updateGlassViewStyle(isFullScreen: true)
            
            // Set frame to fill the screen
            window.setFrame(screenFrame, display: true, animate: true)
        } else {
            // Restore windowed style
            updateGlassViewStyle(isFullScreen: false)
            
            if let savedFrame = savedWindowFrame {
                window.setFrame(savedFrame, display: true, animate: true)
            } else {
                let defaultFrame = NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: targetWidth, height: targetHeight)
                window.setFrame(defaultFrame, display: true, animate: true)
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func updateGlassViewStyle(isFullScreen: Bool) {
        guard let window = self.window,
              let glassView = window.contentView as? CustomGlassView else { return }
        
        if isFullScreen {
            glassView.maskImage = nil
            glassView.layer?.cornerRadius = 0
            glassView.layer?.borderWidth = 0
            glassView.blendingMode = .behindWindow
            glassView.material = .hudWindow
        } else {
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
            glassView.blendingMode = .behindWindow
            glassView.material = .hudWindow
        }
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
        if initial {
            window.styleMask = [.borderless, .resizable]
            window.collectionBehavior = [.managed]
            window.isMovableByWindowBackground = true
            window.hasShadow = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.center() // Center on screen on first load
        }
        
        window.backgroundColor = .clear
        window.isOpaque = false
        window.invalidateShadow()
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showCreateSheet = false
    @State private var showSizesMenu = false
    @State private var hoverTask: Task<Void, Never>? = nil
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Desktop Content Area
                VStack(spacing: 0) {
                    // Unified Header Bar (Transparent background + thin divider line)
                    HStack {
                        // Left: spacer balancing the fixed traffic-light overlay
                        Color.clear
                            .frame(width: 60, height: 12)

                        Spacer()
                        
                        // Center: Page Title
                        if let activeApp = model.activeApp {
                            Text(activeAppTitle(activeApp))
                                .font(.headline).bold()
                                .foregroundStyle(Color.white)
                        } else {
                            Text("andross")
                                .font(.system(.headline, design: .monospaced)).bold()
                                .foregroundStyle(Color.androidGreen)
                        }
                        
                        Spacer()
                        
                        // Right: Balance spacer to keep title perfectly centered
                        Color.clear
                            .frame(width: 60, height: 12)
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 32)
                    .padding(.bottom, 12)
                    .background(Color.clear)
                    
                    Divider().background(Color.slateBorder)
                    
                    // Main Content Canvas
                    if let activeApp = model.activeApp {
                        // Display inside app view
                        ScrollView {
                            appContentView(activeApp)
                                .padding(16)
                        }
                        .background(Color.clear)
                    } else {
                        // Home: the user's own Android apps, like a real phone.
                        VStack(spacing: 0) {
                            if model.activeSerial != nil {
                                // Status chip: which phone / which identity
                                let identityName = model.identities.first { $0.userId == model.activeIdentityId }?.name ?? "Owner"
                                Text("\(model.activeDeviceName) · \(identityName)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.slateTextDim)
                                    .padding(.top, 10)

                                if model.activePackages.isEmpty {
                                    Spacer()
                                    VStack(spacing: 10) {
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.system(size: 28))
                                            .foregroundStyle(Color.slateTextDim)
                                        Text("No apps yet.")
                                            .font(.caption)
                                            .foregroundStyle(Color.slateTextDim)
                                        Text("Drop an .apk file anywhere in this window,\nor install from the store inside the phone.")
                                            .font(.system(size: 10))
                                            .multilineTextAlignment(.center)
                                            .foregroundStyle(Color.slateTextDim.opacity(0.8))
                                    }
                                    Spacer()
                                } else {
                                    ScrollView {
                                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(86), spacing: 18), count: model.isLandscape ? 6 : 3), spacing: 20) {
                                            ForEach(model.activePackages, id: \.self) { pkg in
                                                androidAppIcon(packageName: pkg) {
                                                    model.launchApp(packageName: pkg)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.top, 18)
                                    }
                                }
                            } else {
                                Spacer()
                                VStack(spacing: 10) {
                                    Image(systemName: "iphone.slash")
                                        .font(.system(size: 28))
                                        .foregroundStyle(Color.slateTextDim)
                                    Text("No phone is running.")
                                        .font(.caption)
                                        .foregroundStyle(Color.slateTextDim)
                                    Text("Your apps will appear here once a phone is on.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.slateTextDim.opacity(0.8))
                                }
                                Spacer()
                            }

                            // Dock: the three system surfaces.
                            HStack(spacing: model.isLandscape ? 48 : 36) {
                                dockIcon(title: "Devices", icon: "iphone") {
                                    withAnimation(.easeIn(duration: 0.15)) { model.activeApp = .devices }
                                }
                                dockIcon(title: "Sandboxes", icon: "person.2") {
                                    withAnimation(.easeIn(duration: 0.15)) { model.activeApp = .sandboxes }
                                }
                                dockIcon(title: "Settings", icon: "gearshape") {
                                    withAnimation(.easeIn(duration: 0.15)) { model.activeApp = .settings }
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 22)
                            .liquidGlassBackground(cornerRadius: 22)
                            .padding(.bottom, 8)
                            .padding(.top, 6)
                        }
                        .background(Color.clear)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Bottom Android Gesture Navigation Bar Pill — a real Button so
                // it always wins hit-testing against window-background dragging.
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
            .frame(width: model.currentWidth, height: model.currentHeight)
            .background(Color.slateDeep.opacity(0.2))
            .background(WindowConfigurator(width: model.currentWidth, height: model.currentHeight)) // Apply NSWindow configurations
            
            // Custom hover menu overlay (lightweight, zero event blocking)
            if showSizesMenu {
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
                .liquidGlassBackground(cornerRadius: 12)
                .position(x: 106, y: 110)
                .onHover { hovering in
                    if hovering {
                        hoverTask?.cancel()
                    } else {
                        hoverTask = Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            if !Task.isCancelled {
                                withAnimation(.easeIn(duration: 0.15)) {
                                    showSizesMenu = false
                                }
                            }
                        }
                    }
                }
                .transition(.opacity)
            }
            
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
        // Traffic lights pinned to the window's top-left corner, outside the
        // animating layout (they used to drift during size-change springs).
        .overlay(alignment: .topLeading) {
            trafficLights
                .padding(.leading, 36)
                .padding(.top, 34)
                .transaction { $0.animation = nil }
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
    
    // Custom traffic lights: real Buttons (not tap gestures) so they always
    // win hit-testing against window-background dragging.
    private var trafficLights: some View {
        HStack(spacing: 8) {
            Button { NSApp.terminate(nil) } label: {
                Circle().fill(Color.slateRed).frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Button { NSApp.keyWindow?.miniaturize(nil) } label: {
                Circle().fill(Color(hex: 0xFFBD2E)).frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize")

            // Green: fullscreen toggle on click, preset sizes on hover
            Button {
                NotificationCenter.default.post(name: NSNotification.Name("ToggleMaximize"), object: nil)
            } label: {
                Circle().fill(Color.androidGreen).frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom")
            .onHover { hovering in
                if hovering {
                    hoverTask?.cancel()
                    withAnimation(.easeOut(duration: 0.15)) {
                        showSizesMenu = true
                    }
                } else {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms delay
                        if !Task.isCancelled {
                            withAnimation(.easeIn(duration: 0.15)) {
                                showSizesMenu = false
                            }
                        }
                    }
                }
            }
        }
    }

    private func activeAppTitle(_ app: AppModel.ActiveApp) -> String {
        switch app {
        case .devices: return "Devices"
        case .sandboxes: return "Sandboxes"
        case .settings: return "Settings"
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
        }
    }
    
    /// Dock icon for the three system surfaces.
    private func dockIcon(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.androidGreen)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private static let avatarPalette: [Color] = [
        Color(hex: 0x3DDC84), Color(hex: 0x37B9C5), Color(hex: 0x5E9CF2),
        Color(hex: 0xB387F0), Color(hex: 0xE8A06A), Color(hex: 0xE87C9A),
    ]

    /// Home-screen icon for an installed Android app: letter avatar tile
    /// (we can't cheaply extract real icons from APKs) + display name.
    private func androidAppIcon(packageName: String, action: @escaping () -> Void) -> some View {
        let name = AppCatalog.displayName(for: packageName)
        let color = Self.avatarPalette[abs(packageName.hashValue) % Self.avatarPalette.count]
        return Button(action: action) {
            VStack(spacing: 7) {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.slateDeep)
                    .frame(width: 58, height: 58)
                    .background(
                        LinearGradient(colors: [color, color.opacity(0.72)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(maxWidth: 82)
            }
        }
        .buttonStyle(.plain)
        .help(packageName)
        .accessibilityLabel(name)
    }
    
    private func sizeMenuButton(title: String, isTablet: Bool, isLandscape: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                model.isTablet = isTablet
                model.isLandscape = isLandscape
                model.refreshStorageStats()
            }
            showSizesMenu = false
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
                                let ok = EmulatorManager.shared.startAVD(name: name)
                                if ok {
                                    model.log("Boot started — the phone window will appear shortly.")
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
