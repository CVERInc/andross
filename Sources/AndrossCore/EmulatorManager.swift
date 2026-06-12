import Foundation

public final class EmulatorManager: Sendable {
    public static let shared = EmulatorManager()
    
    public let androidHome = "/opt/homebrew/share/android-commandlinetools"
    
    private init() {}
    
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
        let result = Shell.runStreaming(["brew", "install", "--cask", "temurin"]) { line, transient in
            onLine(line, transient)
        }
        return result.ok
    }
    
    /// Install Android SDK Command-line Tools via Homebrew.
    @discardableResult
    public func installSdk(onLine: @escaping @Sendable (String, Bool) -> Void) -> Bool {
        let result = Shell.runStreaming(["brew", "install", "--cask", "android-commandlinetools"]) { line, transient in
            onLine(line, transient)
        }
        return result.ok
    }
    
    /// Scan and return a list of created Android Virtual Devices (AVD).
    public func listAVDs() -> [String] {
        let result = Shell.run(["avdmanager", "list", "avd"])
        guard result.ok else { return [] }
        
        var list: [String] = []
        let lines = result.stdout.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("Name:") {
                let name = line.replacingOccurrences(of: "Name:", with: "")
                               .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    list.append(name)
                }
            }
        }
        return list
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
    public enum SystemType: Int {
        case googlePlay = 1
        case aospWithAurora = 2
        case aospBlank = 3
        
        var sdkImage: String {
            switch self {
            case .googlePlay:
                return "system-images;android-33;google_apis_playstore;arm64-v8a"
            case .aospWithAurora, .aospBlank:
                return "system-images;android-33;default;arm64-v8a"
            }
        }
    }
    
    /// Create a new virtual device (AVD) and download required SDK components.
    public func createAVD(
        name: String,
        type: SystemType,
        profile: DeviceProfile,
        onProgress: @escaping @Sendable (String, Bool) -> Void
    ) async -> Bool {
        onProgress("Accepting Google SDK licenses...", false)
        Shell.run(["sdkmanager", "--licenses"], stdin: "y\ny\ny\ny\ny\ny\ny\n")
        
        let image = type.sdkImage
        onProgress("Downloading Android system image & emulator binaries, this may take a few minutes...", false)
        
        let dlResult = Shell.runStreaming(["sdkmanager", image, "platform-tools", "emulator"]) { line, transient in
            onProgress(line, transient)
        }
        guard dlResult.ok else {
            onProgress("Failed to download SDK components. Please check your network connection!", false)
            return false
        }
        
        onProgress("Creating virtual device '\(name)'...", false)
        let createArgs = ["avdmanager", "create", "avd", "-n", name, "-k", image, "--device", "pixel_6", "--force"]
        let createResult = Shell.run(createArgs, stdin: "no\n")
        
        guard createResult.ok else {
            onProgress("Failed to create Android Virtual Device (AVD).", false)
            return false
        }
        
        // Write custom resolution config to config.ini
        let home = NSHomeDirectory()
        let configPath = URL(fileURLWithPath: home)
            .appendingPathComponent(".android")
            .appendingPathComponent("avd")
            .appendingPathComponent("\(name).avd")
            .appendingPathComponent("config.ini")
            
        if FileManager.default.fileExists(atPath: configPath.path) {
            if let configContent = try? String(contentsOf: configPath, encoding: .utf8) {
                var lines = configContent.components(separatedBy: .newlines)
                
                // Remove existing resolution keys
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
        }
        
        // Sideload Aurora Store if required
        if type == .aospWithAurora {
            onProgress("Downloading open-source Aurora Store APK...", false)
            let tmpDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".andross_tmp")
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let apkURL = tmpDir.appendingPathComponent("AuroraStore.apk")
            
            let downloadCmd = ["curl", "-L", "-o", apkURL.path, "https://files.auroraoss.com/AuroraStore/Stable/AuroraStore-Stable.apk"]
            let dlApkResult = Shell.run(downloadCmd)
            if dlApkResult.ok {
                onProgress("Aurora Store APK downloaded. It will be automatically installed on first launch.", false)
            } else {
                onProgress("Aurora Store download failed, but the virtual device was successfully created.", false)
            }
        }
        
        onProgress("Virtual device '\(name)' successfully configured!", false)
        return true
    }
    
    /// Start a virtual device (AVD) in the background (non-blocking).
    @discardableResult
    public func startAVD(name: String) -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "emulator -avd \(name) -gpu host -qemu -m 2048 -dns-server 8.8.8.8"]
        
        do {
            try process.run()
            
            // Check if we need to auto-install Aurora Store
            let tmpDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".andross_tmp")
            let apkURL = tmpDir.appendingPathComponent("AuroraStore.apk")
            if FileManager.default.fileExists(atPath: apkURL.path) {
                Task {
                    _ = Shell.run(["adb", "wait-for-device"])
                    _ = Shell.run(["adb", "install", apkURL.path])
                    try? FileManager.default.removeItem(at: apkURL)
                }
            }
            return true
        } catch {
            return false
        }
    }
    
    /// Gracefully terminate all running emulator instances.
    @discardableResult
    public func stopAll() -> Bool {
        let result = Shell.run(["adb", "devices"])
        guard result.ok else { return false }
        
        let lines = result.stdout.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("emulator") {
                let parts = line.components(separatedBy: .whitespacesAndNewlines)
                if let dev = parts.first, !dev.isEmpty {
                    Shell.run(["adb", "-s", dev, "emu", "kill"])
                }
            }
        }
        return true
    }
    
    /// Install a local APK file to the active emulator.
    @discardableResult
    public func installAPK(path: String, onLine: @escaping @Sendable (String, Bool) -> Void) -> Bool {
        onLine("Waiting for virtual device to respond...", false)
        Shell.run(["adb", "wait-for-device"])
        onLine("Installing \(URL(fileURLWithPath: path).lastPathComponent)...", false)
        let result = Shell.runStreaming(["adb", "install", path]) { line, transient in
            onLine(line, transient)
        }
        return result.ok
    }
    
    // MARK: - Identity (User Profile) Management
    
    public struct AndroidUser: Sendable, Identifiable, Hashable {
        public var id: Int { userId }
        public let userId: Int
        public let name: String
        public let isRunning: Bool
        
        public init(userId: Int, name: String, isRunning: Bool) {
            self.userId = userId
            self.name = name
            self.isRunning = isRunning
        }
    }
    
    /// Retrieve all user profile identities (Tanks) from the active AVD.
    public func listUsers() -> [AndroidUser] {
        let devices = Shell.run(["adb", "devices"])
        guard devices.ok && devices.stdout.contains("emulator") else { return [] }
        
        let result = Shell.run(["adb", "shell", "pm", "list", "users"])
        guard result.ok else { return [] }
        
        var list: [AndroidUser] = []
        let lines = result.stdout.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("UserInfo{") {
                guard let startIdx = line.firstIndex(of: "{"),
                      let endIdx = line.firstIndex(of: "}") else { continue }
                let info = String(line[line.index(after: startIdx)..<endIdx])
                let parts = info.components(separatedBy: ":")
                guard parts.count >= 2, let userId = Int(parts[0]) else { continue }
                let name = parts[1]
                let isRunning = line.contains("running")
                list.append(AndroidUser(userId: userId, name: name, isRunning: isRunning))
            }
        }
        return list
    }
    
    /// Create a new user identity (Tank) inside the active AVD.
    @discardableResult
    public func createUser(name: String) -> Int? {
        let result = Shell.run(["adb", "shell", "pm", "create-user", name])
        guard result.ok else { return nil }
        
        let parts = result.stdout.components(separatedBy: .whitespacesAndNewlines)
        if let last = parts.last, let userId = Int(last) {
            Shell.run(["adb", "shell", "am", "start-user", "\(userId)"])
            return userId
        }
        return nil
    }
    
    /// Switch active screen display focus to the specified user identity (Tank).
    @discardableResult
    public func switchUser(id: Int) -> Bool {
        let result = Shell.run(["adb", "shell", "am", "switch-user", "\(id)"])
        return result.ok
    }
    
    /// Instantly enable/clone an app installed on the main user profile to a sub-identity.
    @discardableResult
    public func cloneApp(packageName: String, toUser userId: Int) -> Bool {
        let result = Shell.run(["adb", "shell", "pm", "install-existing", "--user", "\(userId)", packageName])
        return result.ok
    }
    
    /// Remove the specified user profile identity (Tank).
    @discardableResult
    public func deleteUser(id: Int) -> Bool {
        let result = Shell.run(["adb", "shell", "pm", "remove-user", "\(id)"])
        return result.ok
    }
    
    // MARK: - Uninstallation / Purging (Clean Uninstall)
    
    /// Uninstall Android SDK Command-line Tools via Homebrew.
    @discardableResult
    public func uninstallSdk(onLine: @escaping @Sendable (String, Bool) -> Void) -> Bool {
        let result = Shell.runStreaming(["brew", "uninstall", "--cask", "android-commandlinetools"]) { line, transient in
            onLine(line, transient)
        }
        return result.ok
    }
    
    /// Uninstall Java (Temurin JRE) via Homebrew.
    @discardableResult
    public func uninstallJava(onLine: @escaping @Sendable (String, Bool) -> Void) -> Bool {
        let result = Shell.runStreaming(["brew", "uninstall", "--cask", "temurin"]) { line, transient in
            onLine(line, transient)
        }
        return result.ok
    }
    
    /// Purge Android Virtual Devices (AVD) and configurations directory.
    @discardableResult
    public func purgeAVDFiles() -> Bool {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let androidDir = URL(fileURLWithPath: home).appendingPathComponent(".android")
        if fm.fileExists(atPath: androidDir.path) {
            do {
                try fm.removeItem(at: androidDir)
                return true
            } catch {
                return false
            }
        }
        return true
    }
    
    /// Purge temporary files generated by andross (~/.andross_tmp).
    @discardableResult
    public func purgeTempFiles() -> Bool {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let tmpDir = URL(fileURLWithPath: home).appendingPathComponent(".andross_tmp")
        if fm.fileExists(atPath: tmpDir.path) {
            do {
                try fm.removeItem(at: tmpDir)
                return true
            } catch {
                return false
            }
        }
        return true
    }
    
    // MARK: - Storage Stats
    
    public struct AppStorageStats: Sendable, Codable, Hashable {
        public let packageName: String
        public let appName: String
        public let apkSize: Int64
        public let dataSize: Int64
        public let cacheSize: Int64
        public let totalSize: Int64
        
        public init(packageName: String, appName: String, apkSize: Int64, dataSize: Int64, cacheSize: Int64, totalSize: Int64) {
            self.packageName = packageName
            self.appName = appName
            self.apkSize = apkSize
            self.dataSize = dataSize
            self.cacheSize = cacheSize
            self.totalSize = totalSize
        }
    }
    
    /// Calculate size of a directory on the macOS host in bytes.
    public func getDirectorySize(path: String) -> Int64 {
        let result = Shell.run(["du", "-sk", path])
        if result.ok {
            let parts = result.stdout.components(separatedBy: .whitespacesAndNewlines)
            if let first = parts.first, let kb = Int64(first.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return kb * 1024
            }
        }
        return 0
    }
    
    /// Get size of a file on the macOS host in bytes.
    public func getFileSize(path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.size] as? Int64 ?? 0
    }
    
    /// Get the storage size of an Android application.
    public func getAppStorageStats(packageName: String, userId: Int) -> AppStorageStats? {
        // 1. Get APK path and size
        let pathRes = Shell.run(["adb", "shell", "pm", "path", packageName])
        guard pathRes.ok, !pathRes.stdout.isEmpty else { return nil }
        
        var apkSize: Int64 = 0
        let lines = pathRes.stdout.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("package:") {
                let path = line.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    let sizeRes = Shell.run(["adb", "shell", "ls", "-l", path])
                    if sizeRes.ok {
                        let parts = sizeRes.stdout.components(separatedBy: .whitespaces)
                        for part in parts {
                            if let bytes = Int64(part.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                apkSize = bytes
                                break
                            }
                        }
                    }
                }
            }
        }
        
        // 2. Get User Data and Cache size via du
        var dataSize: Int64 = 0
        var cacheSize: Int64 = 0
        
        let dataPath = "/data/user/\(userId)/\(packageName)"
        let duRes = Shell.run(["adb", "shell", "du", "-sk", dataPath])
        if duRes.ok {
            let parts = duRes.stdout.components(separatedBy: .whitespacesAndNewlines)
            if let first = parts.first, let kb = Int64(first.trimmingCharacters(in: .whitespacesAndNewlines)) {
                dataSize = kb * 1024
            }
        }
        
        let cachePath = "\(dataPath)/cache"
        let duCacheRes = Shell.run(["adb", "shell", "du", "-sk", cachePath])
        if duCacheRes.ok {
            let parts = duCacheRes.stdout.components(separatedBy: .whitespacesAndNewlines)
            if let first = parts.first, let kb = Int64(first.trimmingCharacters(in: .whitespacesAndNewlines)) {
                cacheSize = kb * 1024
            }
        }
        
        let totalSize = apkSize + dataSize
        
        let appName: String
        if packageName.contains("line") {
            appName = "LINE"
        } else if packageName.contains("aurora") {
            appName = "Aurora Store"
        } else {
            appName = packageName
        }
        
        return AppStorageStats(
            packageName: packageName,
            appName: appName,
            apkSize: apkSize,
            dataSize: dataSize,
            cacheSize: cacheSize,
            totalSize: totalSize
        )
    }
}
