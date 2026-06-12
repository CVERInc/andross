import Foundation
import AndrossCore

// Integration harness (not a product CLI): boots a real AVD headless and
// drives the full identity lifecycle through AndrossCore, the same code
// paths the GUI uses. Exits non-zero on the first failure.
//
// Run via: ./scripts/test.sh integration

let manager = EmulatorManager.shared
var bootedByUs = false

@MainActor func cleanup() {
    if bootedByUs {
        _ = manager.stopAll()
    }
}

@MainActor func fail(_ message: String) -> Never {
    print("✗ \(message)")
    cleanup()
    exit(1)
}

@MainActor func pass(_ message: String) {
    print("✓ \(message)")
}

/// Poll until `condition` is true or the timeout elapses.
@MainActor func waitFor(_ what: String, timeoutSeconds: Int = 30, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 2)
    }
    print("… timed out waiting for \(what)")
    return false
}

// 0. Preconditions
guard manager.emulatorInstalled else {
    fail("emulator engine not installed (\(manager.emulatorPath))")
}
let avds = manager.listAVDs()
guard let avd = avds.first else {
    fail("no AVD configured — create one in the app first")
}
pass("AVDs found: \(avds.joined(separator: ", ")) — using '\(avd)'")

guard manager.connectedEmulators().isEmpty else {
    fail("an emulator is already running — stop it before the integration run")
}

// 1. Boot headless
guard manager.startAVD(name: avd, headless: true) else {
    fail("startAVD failed to spawn the emulator process")
}
bootedByUs = true
pass("emulator process spawned (headless), waiting for boot…")

guard let serial = manager.waitForBootedEmulator(timeoutSeconds: 300) else {
    fail("device did not finish booting within 5 minutes")
}
pass("booted: \(serial)")

// 2. Running AVD mapping
let running = manager.runningAVDs()
guard running.contains(where: { $0.serial == serial && $0.avdName == avd }) else {
    fail("runningAVDs() did not map \(serial) → \(avd); got \(running)")
}
pass("runningAVDs maps \(serial) → \(avd)")

// 3. User listing (+ clean up leftovers from earlier aborted runs)
var usersBefore = manager.listUsers(serial: serial)
guard usersBefore.contains(where: { $0.userId == 0 }) else {
    fail("owner user (0) not found in: \(usersBefore)")
}
for leftover in usersBefore where leftover.name == "andross-it" {
    if manager.deleteUser(serial: serial, id: leftover.userId) {
        print("… removed leftover test identity \(leftover.userId) from an earlier run")
    }
}
usersBefore = manager.listUsers(serial: serial)
pass("listUsers: \(usersBefore.map { "\($0.userId):\($0.name)" }.joined(separator: ", "))")

// 4. Create identity
let testUserName = "andross-it"
guard let newId = manager.createUser(serial: serial, name: testUserName) else {
    fail("createUser failed")
}
pass("created identity '\(testUserName)' with id \(newId)")

guard manager.listUsers(serial: serial).contains(where: { $0.userId == newId }) else {
    fail("new identity \(newId) missing from listUsers")
}

// 5. Switch to it and verify foreground user follows
guard manager.switchUser(serial: serial, id: newId) else {
    fail("switchUser(\(newId)) command failed")
}
guard waitFor("foreground user == \(newId)", timeoutSeconds: 60,
              condition: { manager.currentUserId(serial: serial) == newId }) else {
    fail("foreground user never became \(newId)")
}
pass("switched foreground to identity \(newId)")

// 5b. Optional: install a real APK (owner-only) to exercise the install and
// clone paths end-to-end. Set ANDROSS_IT_APK=/path/to/test.apk to enable.
if let apkPath = ProcessInfo.processInfo.environment["ANDROSS_IT_APK"] {
    guard FileManager.default.fileExists(atPath: apkPath) else {
        fail("ANDROSS_IT_APK set but file missing: \(apkPath)")
    }
    guard manager.installAPK(serial: serial, path: apkPath, userId: 0,
                             onLine: { line, _ in print("  · \(line)") }) else {
        fail("installAPK failed for \(apkPath)")
    }
    pass("installed test APK for owner only")
}

// 6. Package listing + clone (only if a third-party app exists on owner)
let ownerPackages = manager.listThirdPartyPackages(serial: serial, userId: 0)
pass("owner third-party packages: \(ownerPackages.isEmpty ? "(none)" : ownerPackages.joined(separator: ", "))")

if let pkg = ownerPackages.first {
    guard manager.cloneApp(serial: serial, packageName: pkg, toUser: newId) else {
        fail("cloneApp(\(pkg) → user \(newId)) failed")
    }
    let cloned = manager.listThirdPartyPackages(serial: serial, userId: newId)
    guard cloned.contains(pkg) else {
        fail("\(pkg) not visible to user \(newId) after clone; saw \(cloned)")
    }
    pass("cloned \(pkg) into identity \(newId) and verified visibility")

    if let stats = manager.getAppStorageStats(serial: serial, packageName: pkg, userId: newId) {
        let data = stats.dataSize.map { "\($0)B" } ?? "n/a"
        pass("storage stats for \(pkg): apk=\(stats.apkSize)B data=\(data)")
        guard stats.apkSize > 0 else { fail("apkSize should be > 0") }
    } else {
        fail("getAppStorageStats returned nil for \(pkg)")
    }
} else {
    print("… no third-party app on owner; clone/storage steps skipped (fresh image)")
}

// 7. Delete the test identity while it is still in the foreground —
// exercises deleteUser's switch-away-first safety path.
guard manager.deleteUser(serial: serial, id: newId) else {
    fail("deleteUser(\(newId)) failed")
}
guard waitFor("identity \(newId) removed", timeoutSeconds: 30,
              condition: { !manager.listUsers(serial: serial).contains { $0.userId == newId } }) else {
    fail("identity \(newId) still present after deletion")
}
pass("test identity \(newId) deleted")

// 8. Guard: deleting owner must be refused
guard manager.deleteUser(serial: serial, id: 0) == false else {
    fail("deleteUser(0) must be refused")
}
pass("owner deletion correctly refused")

// 8b. Remove the test APK again if we installed one.
if ProcessInfo.processInfo.environment["ANDROSS_IT_APK"] != nil,
   let pkg = ProcessInfo.processInfo.environment["ANDROSS_IT_APK_PKG"] {
    guard manager.uninstallPackage(serial: serial, packageName: pkg) else {
        fail("uninstallPackage(\(pkg)) failed")
    }
    pass("test APK \(pkg) uninstalled")
}

// 9. Shutdown
let stopped = manager.stopAll()
guard stopped >= 1 else { fail("stopAll reported nothing to stop") }
guard waitFor("emulator shutdown", timeoutSeconds: 60,
              condition: { manager.connectedEmulators().isEmpty }) else {
    fail("emulator still registered with adb after stopAll")
}
bootedByUs = false
pass("emulator shut down cleanly")

print("\n✓ integration suite passed")
