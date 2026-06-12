import Foundation
import AndrossCore

let args = CommandLine.arguments

func showBanner() {
    print("""
    \u{001B}[0;34m=======================================\u{001B}[0m
    \u{001B}[0;32m              andross CLI              \u{001B}[0m
    \u{001B}[0;33m     Open-source, Native M1-M4 AVDs     \u{001B}[0m
    \u{001B}[0;34m=======================================\u{001B}[0m
    """)
}

func showHelp() {
    showBanner()
    print("""
    Usage: andross [command] [args]
    
    Available Commands:
      setup                   Interactive setup to create a new virtual phone (AVD)
      start [name]            Start a specific virtual phone in the background
      stop                    Stop all running virtual phones
      list                    List all created virtual phones
      install [path]          Install a local .apk file to the active phone
      uninstall               Clean uninstall and purge all selected components from Mac
      storage                 Show disk storage sizes of host (andross) and AVD apps
      
      identity-list           List all user identities (Tanks) in the running phone
      identity-create [name]  Create a new identity and clone LINE
      identity-switch [id]    Switch display screen to the specified identity ID
      identity-delete [id]    Delete the specified identity ID
      
      help                    Show this help menu
    """)
}

func printStreamedLine(_ line: String, transient: Bool) {
    if transient {
        print("\r\u{001B}[K  \(line)", terminator: "")
        fflush(stdout)
    } else {
        print("\r\u{001B}[K  \(line)")
    }
}

func runSetup() {
    showBanner()
    
    let manager = EmulatorManager.shared
    
    print("\u{001B}[1;33m[*] Verifying system dependencies...\u{001B}[0m")
    let status = manager.checkStatus()
    
    if !status.brew {
        print("\u{001B}[0;31m[!] Homebrew not found. Please install Homebrew first (https://brew.sh).\u{001B}[0m")
        exit(1)
    }
    
    if !status.java {
        print("\u{001B}[1;33m[*] Java runtime missing. Installing Temurin JRE via Homebrew...\u{001B}[0m")
        let ok = manager.installJava { line, transient in
            printStreamedLine(line, transient: transient)
        }
        if !ok {
            print("\n\u{001B}[0;31m[!] Java installation failed. Please run 'brew install --cask temurin' manually.\u{001B}[0m")
            exit(1)
        }
    }
    
    if !status.sdk {
        print("\u{001B}[1;33m[*] Android command-line tools missing. Installing via Homebrew...\u{001B}[0m")
        let ok = manager.installSdk { line, transient in
            printStreamedLine(line, transient: transient)
        }
        if !ok {
            print("\n\u{001B}[0;31m[!] Android SDK installation failed. Please run 'brew install --cask android-commandlinetools' manually.\u{001B}[0m")
            exit(1)
        }
    }
    
    print("\u{001B}[0;32m[✓] System dependencies verified!\u{001B}[0m\n")
    
    print("\u{001B}[1;33m[*] Creating new virtual device...\u{001B}[0m")
    print("Enter virtual device name (default: andross-phone): ", terminator: "")
    fflush(stdout)
    
    let inputName = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = inputName.isEmpty ? "andross-phone" : inputName
    
    if manager.listAVDs().contains(name) {
        print("\u{001B}[0;31m[!] Error: AVD name '\(name)' is already in use!\u{001B}[0m")
        exit(1)
    }
    
    print("""
    
    Select Android System Type:
      \u{001B}[0;34m1) Google Play Edition\u{001B}[0m (Play Store included, GMS push notifications supported)
      \u{001B}[0;34m2) Open-Source AOSP + Aurora Store\u{001B}[0m (No Google services, download apps via Aurora Store)
      \u{001B}[0;34m3) Blank AOSP Sandbox\u{001B}[0m (Thinnest setup, sideload APKs manually)
    """)
    print("Enter choice (1/2/3): ", terminator: "")
    fflush(stdout)
    
    let optStr = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let opt = Int(optStr), let type = EmulatorManager.SystemType(rawValue: opt) else {
        print("\u{001B}[0;31m[!] Invalid choice. Setup aborted.\u{001B}[0m")
        exit(1)
    }
    
    print("""
    
    Select Device Profile Layout:
      \u{001B}[0;34m1) Phone (Portrait)\u{001B}[0m (1080x2400)
      \u{001B}[0;34m2) Phone (Landscape)\u{001B}[0m (2400x1080)
      \u{001B}[0;34m3) Tablet (Portrait)\u{001B}[0m (1600x2560)
      \u{001B}[0;34m4) Tablet (Landscape)\u{001B}[0m (2560x1600)
    """)
    print("Enter choice (1/2/3/4): ", terminator: "")
    fflush(stdout)
    
    let profileStr = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let profileOpt = Int(profileStr), let profile = EmulatorManager.DeviceProfile(rawValue: profileOpt) else {
        print("\u{001B}[0;31m[!] Invalid choice. Setup aborted.\u{001B}[0m")
        exit(1)
    }
    
    let group = DispatchGroup()
    group.enter()
    Task {
        let success = await manager.createAVD(name: name, type: type, profile: profile) { progressLine, transient in
            printStreamedLine(progressLine, transient: transient)
        }
        if success {
            print("\n\u{001B}[0;32m[✓] Virtual device '\(name)' configured successfully!\u{001B}[0m")
            print("\u{001B}[1;33mHint: Run 'andross start \(name)' to boot the phone!\u{001B}[0m")
        } else {
            print("\n\u{001B}[0;31m[!] Failed to configure virtual device.\u{001B}[0m")
        }
        group.leave()
    }
    group.wait()
}

func runStart(_ name: String) {
    let manager = EmulatorManager.shared
    if !manager.listAVDs().contains(name) {
        print("\u{001B}[0;31m[!] Error: Virtual device '\(name)' not found.\u{001B}[0m")
        runList()
        exit(1)
    }
    
    print("\u{001B}[1;33m[*] Starting virtual device '\(name)' in the background...\u{001B}[0m")
    if manager.startAVD(name: name) {
        print("\u{001B}[0;32m[✓] Boot command sent. Phone window will appear shortly. You can safely close this terminal.\u{001B}[0m")
    } else {
        print("\u{001B}[0;31m[!] Boot failed. Please verify your Android SDK configuration.\u{001B}[0m")
    }
}

func runStop() {
    print("\u{001B}[1;33m[*] Terminating all running Android emulators...\u{001B}[0m")
    if EmulatorManager.shared.stopAll() {
        print("\u{001B}[0;32m[✓] Emulators closed.\u{001B}[0m")
    } else {
        print("\u{001B}[0;32m[✓] No running emulators detected.\u{001B}[0m")
    }
}

func runList() {
    showBanner()
    let list = EmulatorManager.shared.listAVDs()
    if list.isEmpty {
        print(" (No virtual devices configured yet. Run 'andross setup' to create one)")
    } else {
        print("\u{001B}[1;33mConfigured Virtual Devices:\u{001B}[0m")
        for item in list {
            print("  - \(item)")
        }
    }
}

func runInstall(_ path: String) {
    let manager = EmulatorManager.shared
    if !FileManager.default.fileExists(atPath: path) {
        print("\u{001B}[0;31m[!] Error: APK file '\(path)' not found.\u{001B}[0m")
        exit(1)
    }
    
    print("\u{001B}[1;33m[*] Deploying APK to the active phone...\u{001B}[0m")
    let ok = manager.installAPK(path: path) { line, transient in
        printStreamedLine(line, transient: transient)
    }
    if ok {
        print("\n\u{001B}[0;32m[✓] APK installation complete!\u{001B}[0m")
    } else {
        print("\n\u{001B}[0;31m[!] Installation failed. Make sure the virtual phone is booted and unlocked.\u{001B}[0m")
    }
}

func runIdentityList() {
    showBanner()
    let manager = EmulatorManager.shared
    let users = manager.listUsers()
    
    guard !users.isEmpty else {
        print(" (No active phone connected, or no user profiles found. Run 'andross start' first)")
        exit(0)
    }
    
    let activeRes = Shell.run(["adb", "shell", "am", "get-current-user"])
    let activeId = Int(activeRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    
    print("\u{001B}[1;33mActive User Identities (Tanks) on Connected Device:\u{001B}[0m")
    for u in users {
        let activeMark = u.userId == activeId ? " * [\u{001B}[0;32mActive\u{001B}[0m]" : ""
        print("  - ID: \(u.userId) | Name: \(u.name)\(activeMark)")
    }
}

func runIdentityCreate(_ name: String) {
    let manager = EmulatorManager.shared
    print("\u{001B}[1;33m[*] Creating new identity sandbox (Tank) '\(name)'...\u{001B}[0m")
    if let newId = manager.createUser(name: name) {
        print("\u{001B}[0;32m[✓] Identity '\(name)' created successfully (ID: \(newId)).\u{001B}[0m")
        print("\u{001B}[1;33m[*] Clonging LINE package to the new identity sandbox...\u{001B}[0m")
        if manager.cloneApp(packageName: "jp.naver.line.android", toUser: newId) {
            print("\u{001B}[0;32m[✓] LINE successfully cloned and enabled!\u{001B}[0m")
        } else {
            print("  (LINE is not installed on the main profile; skipped cloning. You can install it manually later)")
        }
        print("\u{001B}[1;33m[*] Switching display screen to the new identity...\u{001B}[0m")
        _ = manager.switchUser(id: newId)
    } else {
        print("\u{001B}[0;31m[!] Identity creation failed. Make sure the virtual phone is connected.\u{001B}[0m")
    }
}

func runIdentitySwitch(_ idStr: String) {
    guard let id = Int(idStr) else {
        print("\u{001B}[0;31m[!] Error: Please provide a valid numerical ID.\u{001B}[0m")
        exit(1)
    }
    let manager = EmulatorManager.shared
    print("\u{001B}[1;33m[*] Switching emulator screen focus to identity ID: \(id)...\u{001B}[0m")
    if manager.switchUser(id: id) {
        print("\u{001B}[0;32m[✓] Switch successful.\u{001B}[0m")
    } else {
        print("\u{001B}[0;31m[!] Switch failed. Make sure the identity ID is valid.\u{001B}[0m")
    }
}

func runIdentityDelete(_ idStr: String) {
    guard let id = Int(idStr) else {
        print("\u{001B}[0;31m[!] Error: Please provide a valid numerical ID.\u{001B}[0m")
        exit(1)
    }
    if id == 0 {
        print("\u{001B}[0;31m[!] Error: System Owner identity (ID: 0) cannot be removed.\u{001B}[0m")
        exit(1)
    }
    let manager = EmulatorManager.shared
    print("\u{001B}[1;33m[*] Removing identity ID \(id) from the device...\u{001B}[0m")
    if manager.deleteUser(id: id) {
        print("\u{001B}[0;32m[✓] Identity removed successfully.\u{001B}[0m")
    } else {
        print("\u{001B}[0;31m[!] Removal failed.\u{001B}[0m")
    }
}

func runUninstall() {
    showBanner()
    print("\u{001B}[1;31m[*] Clean Uninstallation Wizard\u{001B}[0m\n")
    print("This wizard will help you clean up andross components from your Mac.\n")
    
    func askYesNo(_ question: String, defaultYes: Bool = false) -> Bool {
        let suffix = defaultYes ? "[Y/n]" : "[y/N]"
        print("\(question) \(suffix): ", terminator: "")
        fflush(stdout)
        let ans = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ans.isEmpty { return defaultYes }
        return ans == "y" || ans == "yes"
    }
    
    let deleteAVD = askYesNo("1. Delete all virtual devices & AVD configs? (~/.android)")
    let removeSdk = askYesNo("2. Uninstall Android SDK via Homebrew?")
    let removeJava = askYesNo("3. Uninstall Java JRE via Homebrew?")
    let deleteTemp = askYesNo("4. Delete all andross temp files? (~/.andross_tmp)", defaultYes: true)
    
    print()
    guard askYesNo("Proceed with purging selected components?") else {
        print("\u{001B}[1;33m[!] Uninstallation aborted.\u{001B}[0m")
        exit(0)
    }
    
    let manager = EmulatorManager.shared
    
    print("\u{001B}[1;33m[*] Stopping all active emulators...\u{001B}[0m")
    _ = manager.stopAll()
    
    if deleteAVD {
        print("\u{001B}[1;33m[*] Purging AVDs and ~/.android directory...\u{001B}[0m")
        _ = manager.purgeAVDFiles()
    }
    
    if removeSdk {
        print("\u{001B}[1;33m[*] Uninstalling Android SDK via Homebrew...\u{001B}[0m")
        _ = manager.uninstallSdk { line, transient in
            printStreamedLine(line, transient: transient)
        }
        print() // Print newline to finalize output
    }
    
    if removeJava {
        print("\u{001B}[1;33m[*] Uninstalling Java JRE via Homebrew...\u{001B}[0m")
        _ = manager.uninstallJava { line, transient in
            printStreamedLine(line, transient: transient)
        }
        print() // Print newline to finalize output
    }
    
    if deleteTemp {
        print("\u{001B}[1;33m[*] Removing temporary files (~/.andross_tmp)...\u{001B}[0m")
        _ = manager.purgeTempFiles()
    }
    
    print("\n\u{001B}[0;32m[✓] Purge complete! Selected components have been removed.\u{001B}[0m")
    print("You can now safely delete this 'andross' folder/binary.")
}

func runStorage() {
    showBanner()
    let manager = EmulatorManager.shared
    let fm = FileManager.default
    let home = NSHomeDirectory()
    
    print("\u{001B}[1;33m[*] Mac Host Storage Stats:\u{001B}[0m")
    
    // andross App size
    let appPath = "/Users/chodaict/Applications/andross.app"
    let appSize = fm.fileExists(atPath: appPath) ? manager.getDirectorySize(path: appPath) : manager.getDirectorySize(path: Bundle.main.bundlePath)
    print("  - andross App Bundle:      \(ByteCountFormatter.string(fromByteCount: appSize, countStyle: .file))")
    
    // ~/.android size
    let avdPath = URL(fileURLWithPath: home).appendingPathComponent(".android").path
    let avdSize = manager.getDirectorySize(path: avdPath)
    print("  - AVD Configs (~/.android):  \(ByteCountFormatter.string(fromByteCount: avdSize, countStyle: .file))")
    
    // ~/.andross_tmp size
    let tempPath = URL(fileURLWithPath: home).appendingPathComponent(".andross_tmp").path
    let tempSize = manager.getDirectorySize(path: tempPath)
    print("  - Temp Cache (~/.andross_tmp): \(ByteCountFormatter.string(fromByteCount: tempSize, countStyle: .file))")
    
    print("\n\u{001B}[1;33m[*] Android App Storage Breakdown:\u{001B}[0m")
    let devices = Shell.run(["adb", "devices"])
    if devices.ok && devices.stdout.contains("emulator") {
        let activeRes = Shell.run(["adb", "shell", "am", "get-current-user"])
        let activeId = Int(activeRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        
        let packages = ["jp.naver.line.android", "com.aurora.store"]
        var found = false
        for pkg in packages {
            if let stats = manager.getAppStorageStats(packageName: pkg, userId: activeId) {
                found = true
                print("\n  \u{001B}[1;32mPackage: \(pkg) (\(stats.appName))\u{001B}[0m")
                print("    - App size (APK): \(ByteCountFormatter.string(fromByteCount: stats.apkSize, countStyle: .file))")
                print("    - User data:      \(ByteCountFormatter.string(fromByteCount: stats.dataSize, countStyle: .file))")
                print("    - Cache size:     \(ByteCountFormatter.string(fromByteCount: stats.cacheSize, countStyle: .file))")
                print("    - Total:          \(ByteCountFormatter.string(fromByteCount: stats.totalSize, countStyle: .file))")
            }
        }
        if !found {
            print("  (No package statistics found for LINE or Aurora Store on this device)")
        }
    } else {
        print("  (Virtual phone is not active. Run 'andross start' first to query package storage sizes)")
    }
}

// CLI Routing Logic
if args.count < 2 {
    showHelp()
    exit(0)
}

let cmd = args[1]
switch cmd {
case "setup":
    runSetup()
case "start":
    if args.count < 3 {
        print("\u{001B}[0;31m[!] Please specify a virtual device name to start.\u{001B}[0m")
        runList()
        exit(1)
    }
    runStart(args[2])
case "stop":
    runStop()
case "list":
    runList()
case "install":
    if args.count < 3 {
        print("\u{001B}[0;31m[!] Please provide a local .apk file path.\u{001B}[0m")
        exit(1)
    }
    runInstall(args[2])
case "uninstall":
    runUninstall()
case "storage":
    runStorage()
case "identity-list":
    runIdentityList()
case "identity-create":
    if args.count < 3 {
        print("\u{001B}[0;31m[!] Please specify a name for the new identity. Example: andross identity-create creator\u{001B}[0m")
        exit(1)
    }
    runIdentityCreate(args[2])
case "identity-switch":
    if args.count < 3 {
        print("\u{001B}[0;31m[!] Please specify a target identity ID. Example: andross identity-switch 10\u{001B}[0m")
        exit(1)
    }
    runIdentitySwitch(args[2])
case "identity-delete":
    if args.count < 3 {
        print("\u{001B}[0;31m[!] Please specify an identity ID to delete. Example: andross identity-delete 10\u{001B}[0m")
        exit(1)
    }
    runIdentityDelete(args[2])
case "help", "-h", "--help":
    showHelp()
default:
    print("\u{001B}[0;31m[!] Unknown command '\(cmd)'.\u{001B}[0m\n")
    showHelp()
}
