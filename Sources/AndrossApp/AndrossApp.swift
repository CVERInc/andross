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
    
    // Desktop layout state
    enum ActiveApp: String, CaseIterable, Sendable {
        case devices
        case sandboxes
        case installer
        case storage
        case terminal
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
    
    init() {
        refreshAVDs()
        checkDependencies()
        refreshStorageStats()
    }
    
    func refreshAVDs() {
        avds = EmulatorManager.shared.listAVDs()
        if selectedAVD == nil {
            selectedAVD = avds.first
        }
        refreshIdentities()
        refreshStorageStats()
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
            
            // 4. Query Android app packages if emulator is running
            var statsList: [EmulatorManager.AppStorageStats] = []
            let activeUserId = await MainActor.run { self.activeIdentityId }
            
            let devices = Shell.run(["adb", "devices"])
            if devices.ok && devices.stdout.contains("emulator") {
                let packages = ["jp.naver.line.android", "com.aurora.store"]
                for pkg in packages {
                    if let stats = EmulatorManager.shared.getAppStorageStats(packageName: pkg, userId: activeUserId) {
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
        let list = EmulatorManager.shared.listUsers()
        self.identities = list
        
        let activeRes = Shell.run(["adb", "shell", "am", "get-current-user"])
        if activeRes.ok, let activeId = Int(activeRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.activeIdentityId = activeId
        } else {
            self.activeIdentityId = 0
        }
        
        // Retrieve AVD model name
        let nameRes = Shell.run(["adb", "emu", "avd", "name"])
        if nameRes.ok {
            self.activeDeviceName = nameRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let devices = Shell.run(["adb", "devices"])
            if devices.ok && devices.stdout.contains("emulator") {
                self.activeDeviceName = selectedAVD ?? "Active Emulator"
            } else {
                self.activeDeviceName = ""
            }
        }
        
        refreshStorageStats()
    }
    
    func createIdentity(name: String) {
        guard !name.isEmpty else { return }
        log("Creating new identity sandbox [\(name)]...")
        
        Task.detached(priority: .userInitiated) {
            if let newId = EmulatorManager.shared.createUser(name: name) {
                // Automatically clone LINE (jp.naver.line.android) to the new sandbox
                _ = EmulatorManager.shared.cloneApp(packageName: "jp.naver.line.android", toUser: newId)
                
                await MainActor.run {
                    self.log("Successfully created identity [\(name)] (ID: \(newId)) and cloned LINE.")
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
        log("Switching screen display focus to identity ID: \(id)...")
        Task.detached(priority: .userInitiated) {
            let ok = EmulatorManager.shared.switchUser(id: id)
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
        log("Removing identity ID: \(id)...")
        Task.detached(priority: .userInitiated) {
            let ok = EmulatorManager.shared.deleteUser(id: id)
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
                        self.log("  [SDK] " + line, transient: transient)
                    }
                }
            }
            
            if removeJava {
                await MainActor.run { self.progressMessage = "Uninstalling Java JRE via Homebrew..." }
                _ = manager.uninstallJava { line, transient in
                    Task { @MainActor in
                        self.log("  [Java] " + line, transient: transient)
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
                        self.log("  [Java] " + line, transient: transient)
                    }
                }
            }
            
            if !status.sdk {
                await MainActor.run { self.progressMessage = "Installing Android SDK command-line tools..." }
                _ = manager.installSdk { line, transient in
                    Task { @MainActor in
                        self.log("  [SDK] " + line, transient: transient)
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
            let res = Shell.run(["avdmanager", "delete", "avd", "-n", name])
            if res.ok {
                log("Successfully deleted device.")
            } else {
                log("Deletion failed: " + res.stderr)
            }
            selectedAVD = nil
            refreshAVDs()
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
                        // Left: Custom Traffic Lights (Shown directly)
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.slateRed)
                                .frame(width: 12, height: 12)
                                .onTapGesture { NSApp.terminate(nil) }
                            Circle()
                                .fill(Color(hex: 0xFFBD2E))
                                .frame(width: 12, height: 12)
                                .onTapGesture { NSApp.keyWindow?.miniaturize(nil) }
                            
                            // Green: Fullscreen toggle on click, Preset sizes popover on hover
                            Circle()
                                .fill(Color.androidGreen)
                                .frame(width: 12, height: 12)
                                .onTapGesture {
                                    NotificationCenter.default.post(name: NSNotification.Name("ToggleMaximize"), object: nil)
                                }
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
                        .frame(width: 60, alignment: .leading)
                        
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
                        // Desktop home launcher grid centered vertically
                        VStack(spacing: 0) {
                            Spacer()
                            
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 20), count: model.isLandscape ? 5 : 3), spacing: 24) {
                                desktopAppIcon(title: "Devices", icon: "iphone") {
                                    withAnimation(.easeIn(duration: 0.15)) {
                                        model.activeApp = .devices
                                    }
                                }
                                desktopAppIcon(title: "Sandboxes", icon: "person.2") {
                                    withAnimation(.easeIn(duration: 0.15)) {
                                        model.activeApp = .sandboxes
                                    }
                                }
                                desktopAppIcon(title: "Installer", icon: "square.and.arrow.down") {
                                    withAnimation(.easeIn(duration: 0.15)) {
                                        model.activeApp = .installer
                                    }
                                }
                                desktopAppIcon(title: "Storage", icon: "sdcard") {
                                    withAnimation(.easeIn(duration: 0.15)) {
                                        model.activeApp = .storage
                                    }
                                }
                                desktopAppIcon(title: "Terminal", icon: "terminal") {
                                    withAnimation(.easeIn(duration: 0.15)) {
                                        model.activeApp = .terminal
                                    }
                                }
                                desktopAppIcon(title: "Settings", icon: "gearshape") {
                                    withAnimation(.easeIn(duration: 0.15)) {
                                        model.activeApp = .settings
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                            
                            Spacer()
                        }
                        .background(Color.clear)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Bottom Android Gesture Navigation Bar Pill
                Color.clear
                    .frame(height: 24)
                    .overlay(
                        Capsule()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 80, height: 4)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) {
                            model.activeApp = nil
                        }
                    }
                    .padding(.bottom, 12)
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
        // Create Device Sheet
        .sheet(isPresented: $showCreateSheet) {
            VStack(spacing: 16) {
                Text("Create New Virtual Phone").font(.headline)
                
                TextField("Device name (e.g. line-creator)", text: $model.newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                
                Picker("System Type", selection: $model.newType) {
                    Text("Google Play Edition").tag(1)
                    Text("Open-Source AOSP + Aurora").tag(2)
                    Text("Blank AOSP Sandbox").tag(3)
                }
                .frame(width: 260)
                
                Picker("Device Layout / Size", selection: $model.newProfile) {
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
    
    private func activeAppTitle(_ app: AppModel.ActiveApp) -> String {
        switch app {
        case .devices: return "Devices"
        case .sandboxes: return "Sandboxes"
        case .installer: return "Installer"
        case .storage: return "Storage"
        case .terminal: return "Terminal"
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
        case .installer:
            InstallerAppView(model: model)
        case .storage:
            StorageAppView(model: model)
        case .terminal:
            TerminalAppView(model: model)
        case .settings:
            SettingsAppView(model: model)
        }
    }
    
    private func desktopAppIcon(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundStyle(Color.androidGreen)
                }
                .frame(width: 60, height: 60)
                .background(Color.white.opacity(0.06))
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 13.5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13.5, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                
                Text(title)
                    .font(.caption2).bold()
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
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
                Text("Configured Virtual Phones")
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
                    Text("No virtual phones created.")
                        .font(.caption)
                        .foregroundStyle(Color.slateTextDim)
                    Text("Please click Add to create your first layout virtual device.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.slateTextDim)
                }
                .padding(.vertical, 30)
            } else {
                ForEach(model.avds, id: \.self) { name in
                    HStack {
                        Image(systemName: "iphone")
                            .foregroundStyle(model.selectedAVD == name ? Color.androidGreen : Color.slateTextDim)
                        Text(name)
                            .font(.body)
                        Spacer()
                        
                        // Launch button
                        Button {
                            model.selectedAVD = name
                            model.log("Booting virtual device [\(name)]...")
                            let ok = EmulatorManager.shared.startAVD(name: name)
                            if ok {
                                model.log("Boot sequence started.")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                                    model.refreshIdentities()
                                }
                            } else {
                                model.log("Boot sequence failed.")
                            }
                        } label: {
                            Text("Launch")
                                .font(.caption).bold()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        // Delete button
                        Button {
                            model.selectedAVD = name
                            model.deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.slateRed)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .liquidGlassBackground(cornerRadius: 8, customBorderColor: model.selectedAVD == name ? Color.androidGreen.opacity(0.4) : Color.white.opacity(0.1))
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
                Text("Virtual phone must be active to manage sandboxes. Please launch the phone first.")
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
                        TextField("Sandbox name (e.g. line-work)", text: $newIdentityName)
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

// APP VIEW 3: APK Installer app
struct InstallerAppView: View {
    @ObservedObject var model: AppModel
    
    var body: some View {
        VStack(spacing: 16) {
            Text("APK Drag and Drop Installer")
                .font(.subheadline).bold()
            
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 32))
                    .foregroundStyle(model.isDragging ? Color.androidGreen : Color.slateTextDim)
                Text("Drop package .apk file here to deploy")
                    .font(.caption)
                    .foregroundStyle(model.isDragging ? Color.androidGreen : Color.slateTextDim)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(Color.white.opacity(0.05))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        model.isDragging ? Color.androidGreen : Color.white.opacity(0.15),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4])
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $model.isDragging) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url = url, url.pathExtension.lowercased() == "apk" {
                        let apkSize = EmulatorManager.shared.getFileSize(path: url.path)
                        let sizeStr = ByteCountFormatter.string(fromByteCount: apkSize, countStyle: .file)
                        Task { @MainActor in
                            model.log("Deploying dropped APK: \(url.lastPathComponent) (\(sizeStr))...")
                        }
                        _ = EmulatorManager.shared.installAPK(path: url.path) { line, transient in
                            Task { @MainActor in
                                model.log("  [ADB] " + line, transient: transient)
                            }
                        }
                    } else {
                        Task { @MainActor in
                            model.log("Invalid file type. Please drop a valid Android APK file.")
                        }
                    }
                }
                return true
            }
        }
    }
}

// APP VIEW 4: Storage app
struct StorageAppView: View {
    @ObservedObject var model: AppModel
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Storage Breakdown")
                    .font(.subheadline).bold()
                Spacer()
                Button {
                    model.refreshStorageStats()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            
            let narrow = model.currentWidth < 500
            
            let layout = narrow ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            
            layout {
                // macOS storage
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mac Host Files")
                        .font(.caption).bold()
                        .foregroundStyle(Color.white)
                    
                    HStack {
                        Text("andross App Bundle:")
                        Spacer()
                        Text(model.hostAppSize.isEmpty ? "Calculating..." : model.hostAppSize)
                            .foregroundStyle(Color.white)
                    }
                    HStack {
                        Text("AVD Configs (~/.android):")
                        Spacer()
                        Text(model.hostAvdSize.isEmpty ? "Calculating..." : model.hostAvdSize)
                            .foregroundStyle(Color.white)
                    }
                    HStack {
                        Text("Temp Cache (~/.andross_tmp):")
                        Spacer()
                        Text(model.hostTempSize.isEmpty ? "Calculating..." : model.hostTempSize)
                            .foregroundStyle(Color.white)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color.slateTextDim)
                .padding(10)
                .liquidGlassBackground(cornerRadius: 8, customBorderColor: Color.white.opacity(0.1))
                
                // Android AVD storage
                VStack(alignment: .leading, spacing: 8) {
                    Text("Android Sandbox Packages")
                        .font(.caption).bold()
                        .foregroundStyle(Color.white)
                    
                    if model.appStorageStats.isEmpty {
                        Text("No active app stats found. Please start the virtual phone to inspect storage.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.slateTextDim)
                    } else {
                        ForEach(model.appStorageStats, id: \.packageName) { app in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(app.appName)
                                        .font(.caption2).bold()
                                        .foregroundStyle(Color.androidGreen)
                                    Spacer()
                                    Text("Total: \(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))")
                                        .font(.caption2).bold()
                                        .foregroundStyle(Color.white)
                                }
                                HStack {
                                    Text("  • App size (APK):")
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: app.apkSize, countStyle: .file))
                                }
                                HStack {
                                    Text("  • User data:")
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: app.dataSize, countStyle: .file))
                                }
                                HStack {
                                    Text("  • Cache size:")
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: app.cacheSize, countStyle: .file))
                                }
                            }
                            .font(.system(size: 9))
                            .foregroundStyle(Color.slateTextDim)
                            .padding(.bottom, 2)
                        }
                    }
                }
                .padding(10)
                .liquidGlassBackground(cornerRadius: 8, customBorderColor: Color.white.opacity(0.1))
            }
        }
    }
}

// APP VIEW 5: Terminal app
struct TerminalAppView: View {
    @ObservedObject var model: AppModel
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Console Output Logs")
                    .font(.subheadline).bold()
                Spacer()
                Button("Clear Logs") {
                    model.clearLogs()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.logs.isEmpty {
                        Text("No logs captured. Run commands to view stdout streams.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.slateTextDim)
                    } else {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.white)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 280)
            .liquidGlassBackground(cornerRadius: 8, customBorderColor: Color.white.opacity(0.1))
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
                Text("System Dependencies")
                    .font(.caption).bold()
                    .foregroundStyle(Color.white)
                
                VStack(spacing: 8) {
                    dependencyRow(name: "Java Runtime", active: model.depStatus.java)
                    dependencyRow(name: "Android SDK", active: model.depStatus.sdk)
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
                                Label("Auto-Fix Dependencies", systemImage: "wrench.and.screwdriver.fill")
                                    .font(.caption).bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.androidGreen)
                        .controlSize(.small)
                    } else {
                        Text("Please install Homebrew on your Mac to auto-fix missing components.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.slateRed)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }
            }
            
            // Section 2: Emulator Controls
            VStack(alignment: .leading, spacing: 8) {
                Text("Emulator Control")
                    .font(.caption).bold()
                    .foregroundStyle(Color.white)
                
                Button(role: .destructive) {
                    model.log("[*] Shutting down active emulators...")
                    EmulatorManager.shared.stopAll()
                } label: {
                    HStack {
                        Spacer()
                        Label("Stop All Active Emulators", systemImage: "stop.circle.fill")
                            .font(.caption).bold()
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .tint(.slateRed)
                .controlSize(.small)
            }
            
            // Section 3: Clean Maintenance & Purge
            VStack(alignment: .leading, spacing: 10) {
                Text("Maintenance & Clean Uninstall")
                    .font(.caption).bold()
                    .foregroundStyle(Color.white)
                
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Delete AVD virtual config directory (~/.android)", isOn: $model.uninstallDeleteAVDs)
                    Toggle("Uninstall Android SDK tools via brew", isOn: $model.uninstallSdk)
                    Toggle("Uninstall Java Environment via brew", isOn: $model.uninstallJava)
                    Toggle("Remove local cache temporary files (~/.andross_tmp)", isOn: $model.uninstallTemp)
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
                        Label("Perform Clean Uninstall", systemImage: "trash.fill")
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
            Text(active ? "Installed" : "Missing")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? Color.androidGreen : Color.slateRed)
        }
    }
}
