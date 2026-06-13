import Foundation
import AndrossCore

// Zero-dependency unit test runner (Command Line Tools ship neither XCTest
// nor Swift Testing). Pure-parser coverage; exits non-zero on first failure.

var failures = 0

@MainActor
func expect(_ condition: Bool, _ label: String,
            file: StaticString = #file, line: UInt = #line) {
    if condition {
        print("✓ \(label)")
    } else {
        failures += 1
        print("✗ \(label)  (\(file):\(line))")
    }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String,
                               file: StaticString = #file, line: UInt = #line) {
    if actual == expected {
        print("✓ \(label)")
    } else {
        failures += 1
        print("✗ \(label) — expected \(expected), got \(actual)  (\(file):\(line))")
    }
}

// MARK: avdmanager list avd

let avdOutput = """
Available Android Virtual Devices:
    Name: Andross
  Device: pixel_6 (Pixel 6)
    Path: /Users/x/.android/avd/Andross.avd
  Target: Google Play (Google Inc.)
---------
    Name: line-creator
  Device: pixel_6 (Pixel 6)
"""
expectEqual(AndrossParse.avdNames(from: avdOutput), ["Andross", "line-creator"], "avdNames parses two AVDs")
expectEqual(AndrossParse.avdNames(from: "Available Android Virtual Devices:\n"), [], "avdNames handles empty list")

// MARK: adb devices

let devicesOutput = """
List of devices attached
emulator-5554\tdevice
emulator-5556\toffline
R5CT20XXXX\tdevice
emulator-5558\tunauthorized
"""
expectEqual(AndrossParse.emulatorSerials(from: devicesOutput), ["emulator-5554"],
            "emulatorSerials excludes physical/offline/unauthorized devices")
expectEqual(AndrossParse.emulatorSerials(from: "List of devices attached\n\n"), [],
            "emulatorSerials handles no devices")

// MARK: pm list users

let usersOutput = """
Users:
\tUserInfo{0:Owner:c13} running
\tUserInfo{10:line-work:410}
\tUserInfo{11:line-creator:410} running
"""
let users = AndrossParse.users(from: usersOutput)
expectEqual(users.count, 3, "users parses three identities")
expect(users[0].userId == 0 && users[0].name == "Owner" && users[0].isRunning, "owner row parsed with running state")
expect(users[1].userId == 10 && users[1].name == "line-work" && !users[1].isRunning, "secondary row parsed, not running")
expectEqual(users[2].name, "line-creator", "third row name parsed")

// MARK: pm create-user

expectEqual(AndrossParse.createdUserId(from: "Success: created user id 10\n"), 10, "createdUserId parses id 10")
expectEqual(AndrossParse.createdUserId(from: "Success: created user id 137"), 137, "createdUserId parses id 137")
expectEqual(AndrossParse.createdUserId(from: "Error: couldn't create User."), nil, "createdUserId nil on error")
expectEqual(AndrossParse.createdUserId(from: ""), nil, "createdUserId nil on empty")

// MARK: du

expectEqual(AndrossParse.duBytes(from: "1234\t/data/user/0/com.example\n"), 1234 * 1024, "duBytes parses kilobytes")
expectEqual(AndrossParse.duBytes(from: "  42 /tmp\n"), 42 * 1024, "duBytes tolerates leading spaces")
expectEqual(AndrossParse.duBytes(from: "du: /data/user/0/x: Permission denied"), nil, "duBytes nil on permission denied")
expectEqual(AndrossParse.duBytes(from: ""), nil, "duBytes nil on empty")

// MARK: pm list packages

let pkgOutput = """
package:jp.naver.line.android
package:com.aurora.store
"""
expectEqual(AndrossParse.packageNames(from: pkgOutput),
            ["com.aurora.store", "jp.naver.line.android"], "packageNames sorted")

// MARK: pm path (split APKs)

let pathOutput = """
package:/data/app/~~abc==/jp.naver.line.android-xyz==/base.apk
package:/data/app/~~abc==/jp.naver.line.android-xyz==/split_config.arm64_v8a.apk
"""
let apkPaths = AndrossParse.apkPaths(from: pathOutput)
expectEqual(apkPaths.count, 2, "apkPaths parses split APKs")
expect(apkPaths[0].hasSuffix("base.apk"), "apkPaths keeps base.apk first")

// MARK: ls -l

expectEqual(AndrossParse.lsFileSize(from: "-rw-r--r-- 1 system system 123456789 2026-06-13 10:00 base.apk"),
            123_456_789, "lsFileSize finds the size column")
expectEqual(AndrossParse.lsFileSize(from: "ls: /x: No such file or directory"), nil, "lsFileSize nil on missing file")

// MARK: focused package / launcher

expectEqual(AndrossParse.focusedPackage(from: "  mCurrentFocus=Window{1fafa71 u0 com.google.android.dialer/com.google.android.dialer.extensions.GoogleDialtactsActivity}"),
            "com.google.android.dialer", "focusedPackage parses dialer")
expectEqual(AndrossParse.focusedPackage(from: "mCurrentFocus=null"), nil, "focusedPackage nil on null focus")
expectEqual(AndrossParse.focusedPackage(from: ""), nil, "focusedPackage nil on empty")

let launcherOutput = """
priority=0 preferredOrder=NONE match=0x108000 specificIndex=-1 isDefault=true
com.google.android.apps.nexuslauncher/.NexusLauncherActivity
"""
expectEqual(AndrossParse.launcherPackage(from: launcherOutput),
            "com.google.android.apps.nexuslauncher", "launcherPackage parses resolve-activity output")
expectEqual(AndrossParse.launcherPackage(from: "No activity found"), nil, "launcherPackage nil when unresolved")
expectEqual(AndrossParse.resolvedComponent(from: launcherOutput),
            "com.google.android.apps.nexuslauncher/.NexusLauncherActivity", "resolvedComponent keeps full component")

// MARK: boot prop

expect(AndrossParse.bootCompleted(from: "1\n"), "bootCompleted true for 1")
expect(!AndrossParse.bootCompleted(from: ""), "bootCompleted false for empty")
expect(!AndrossParse.bootCompleted(from: "0\n"), "bootCompleted false for 0")

// MARK: result

if failures > 0 {
    print("\n✗ \(failures) failure(s)")
    exit(1)
}
print("\n✓ all unit tests passed")
