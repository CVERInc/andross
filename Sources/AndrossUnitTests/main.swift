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

// MARK: LogBuffer (transient coalescing + cap)

var lb = LogBuffer(limit: 3)
lb.append("a")
lb.append("downloading 10%", transient: true)
lb.append("downloading 80%", transient: true)
expectEqual(lb.lines, ["a", "downloading 80%"], "transient line overwrites previous transient")
lb.append("done")
expectEqual(lb.lines, ["a", "done"], "permanent line replaces last transient")
lb.append("x"); lb.append("y")
expectEqual(lb.lines, ["done", "x", "y"], "buffer caps to limit, dropping oldest")
lb.clear()
expectEqual(lb.lines, [], "clear empties the buffer")
var lb2 = LogBuffer()
lb2.append("one"); lb2.append("two")
expectEqual(lb2.lines, ["one", "two"], "consecutive permanent lines stack")

// MARK: resolveTargetDevice

expectEqual(resolveTargetDevice(isRunning: true, activeDeviceName: "Pixel",
            selectedAVD: "Sel", avds: ["A"]), "Pixel", "running + known name → active device")
expectEqual(resolveTargetDevice(isRunning: true, activeDeviceName: "",
            selectedAVD: "Sel", avds: ["A"]), "Sel", "running + unknown name → selected")
expectEqual(resolveTargetDevice(isRunning: false, activeDeviceName: "Pixel",
            selectedAVD: "Sel", avds: ["A"]), "Sel", "not running → selected (ignore stale name)")
expectEqual(resolveTargetDevice(isRunning: false, activeDeviceName: "",
            selectedAVD: nil, avds: ["First", "B"]), "First", "no selection → first AVD")
expectEqual(resolveTargetDevice(isRunning: false, activeDeviceName: "",
            selectedAVD: nil, avds: []), nil, "nothing available → nil")

// MARK: phoneWindowSize

expectEqual(phoneWindowSize(isTablet: false, isLandscape: false), CGSize(width: 360, height: 800), "phone portrait")
expectEqual(phoneWindowSize(isTablet: false, isLandscape: true), CGSize(width: 800, height: 360), "phone landscape")
expectEqual(phoneWindowSize(isTablet: true, isLandscape: false), CGSize(width: 500, height: 800), "tablet portrait")
expectEqual(phoneWindowSize(isTablet: true, isLandscape: true), CGSize(width: 800, height: 500), "tablet landscape")

// MARK: system image / API level

expectEqual(EmulatorManager.SystemType.googlePlay.sdkImage(apiLevel: 34),
            "system-images;android-34;google_apis_playstore;arm64-v8a", "Play image uses API level")
expectEqual(EmulatorManager.SystemType.aospBlank.sdkImage(apiLevel: 35),
            "system-images;android-35;default;arm64-v8a", "AOSP image uses API level")
expectEqual(EmulatorManager.defaultAPILevel, 34, "default API level is 34 (Android 14)")
expect(EmulatorManager.supportedAPILevels.contains(EmulatorManager.defaultAPILevel),
       "default API level is offered in the picker")
expect(AppCatalog.androidVersionName(apiLevel: 34).contains("Android 14"), "API 34 labelled Android 14")
expectEqual(AppCatalog.androidVersionName(apiLevel: 99), "API 99", "unknown API level falls back to raw")

// MARK: lsFileSize — robustness vs numeric filenames & malformed rows

// A purely numeric filename must NOT be mistaken for the size column.
expectEqual(AndrossParse.lsFileSize(from: "-rw-r--r-- 1 system system 123 2026-06-13 10:00 999999"),
            123, "lsFileSize ignores a numeric filename, takes the real size")
// Directory rows (leading 'd') still parse their size column.
expectEqual(AndrossParse.lsFileSize(from: "drwxr-xr-x 2 root root 4096 2026-06-13 10:00 cache"),
            4096, "lsFileSize parses a directory row")
// Error/garbage rows that contain digits must not yield a phantom size.
expectEqual(AndrossParse.lsFileSize(from: "ls: /data/app/100: No such file or directory"),
            nil, "lsFileSize nil on an error row even with digits present")
expectEqual(AndrossParse.lsFileSize(from: "totally bogus 42 line"),
            nil, "lsFileSize nil when no valid mode column leads the row")
// Multi-line: skip the error line, parse the good one.
expectEqual(AndrossParse.lsFileSize(from: "ls: x: error\n-rw-r--r-- 1 a b 555 2026-06-13 10:00 base.apk"),
            555, "lsFileSize finds the valid row among noise")

// MARK: screencapHeader — malformed / overflow guards

let goodHeader: [UInt8] = {
    var h = [UInt8](repeating: 0, count: 12)
    // width = 1080, height = 2400, little-endian
    let w: UInt32 = 1080, hh: UInt32 = 2400
    for i in 0..<4 { h[i] = UInt8((w >> (8 * UInt32(i))) & 0xFF) }
    for i in 0..<4 { h[4 + i] = UInt8((hh >> (8 * UInt32(i))) & 0xFF) }
    return h
}()
let parsedHeader = AndrossParse.screencapHeader(from: goodHeader)
expect(parsedHeader?.width == 1080 && parsedHeader?.height == 2400, "screencapHeader parses a real frame")
expectEqual(parsedHeader?.pixelByteCount, 1080 * 2400 * 4, "screencapHeader computes RGBA byte count")
expectEqual(AndrossParse.screencapHeader(from: [UInt8](repeating: 0, count: 11)), nil,
            "screencapHeader nil on a short header")
expectEqual(AndrossParse.screencapHeader(from: [UInt8](repeating: 0, count: 12)), nil,
            "screencapHeader nil on a zero (still-booting) header")
// All-0xFF → width/height = 0xFFFFFFFF; must be rejected, not overflow Int.
expectEqual(AndrossParse.screencapHeader(from: [UInt8](repeating: 0xFF, count: 12)), nil,
            "screencapHeader rejects an implausibly huge header without overflowing")
// Exactly at the ceiling is allowed; one past is rejected.
func headerFor(width: UInt32, height: UInt32) -> [UInt8] {
    var h = [UInt8](repeating: 0, count: 12)
    for i in 0..<4 { h[i] = UInt8((width >> (8 * UInt32(i))) & 0xFF) }
    for i in 0..<4 { h[4 + i] = UInt8((height >> (8 * UInt32(i))) & 0xFF) }
    return h
}
let maxDim = UInt32(AndrossParse.maxScreencapDimension)
expect(AndrossParse.screencapHeader(from: headerFor(width: maxDim, height: maxDim)) != nil,
       "screencapHeader allows the max supported dimension")
expectEqual(AndrossParse.screencapHeader(from: headerFor(width: maxDim + 1, height: 1)), nil,
            "screencapHeader rejects one pixel past the ceiling")

// MARK: clampedWindowFrame — restore stays on-screen

let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
// Fully on-screen frame is returned unchanged.
expectEqual(clampedWindowFrame(CGRect(x: 100, y: 100, width: 360, height: 800), visibleFrame: screen),
            CGRect(x: 100, y: 100, width: 360, height: 800), "clampedWindowFrame leaves an on-screen frame alone")
// Off to the right slides back so the whole frame fits.
expectEqual(clampedWindowFrame(CGRect(x: 5000, y: 100, width: 360, height: 800), visibleFrame: screen),
            CGRect(x: 1080, y: 100, width: 360, height: 800), "clampedWindowFrame pulls an off-right frame back in")
// Negative origin (off the left/bottom) is clamped to the screen minimum.
expectEqual(clampedWindowFrame(CGRect(x: -500, y: -500, width: 360, height: 800), visibleFrame: screen),
            CGRect(x: 0, y: 0, width: 360, height: 800), "clampedWindowFrame clamps a negative origin")
// A window larger than the screen is shrunk to fit and pinned to the origin.
expectEqual(clampedWindowFrame(CGRect(x: 200, y: 200, width: 2000, height: 2000), visibleFrame: screen),
            CGRect(x: 0, y: 0, width: 1440, height: 900), "clampedWindowFrame shrinks an oversized window")
// A visibleFrame with a non-zero origin (secondary display / menu bar inset).
let offsetScreen = CGRect(x: 1440, y: 25, width: 1440, height: 875)
expectEqual(clampedWindowFrame(CGRect(x: 0, y: 0, width: 360, height: 800), visibleFrame: offsetScreen),
            CGRect(x: 1440, y: 25, width: 360, height: 800), "clampedWindowFrame respects a non-zero screen origin")

// MARK: gesture coordinate mapping (fittedDeviceRect / devicePoint)

// Portrait phone (1080×2400) inside a wide 800×600 container → pillar-boxed.
let dev = CGSize(width: 1080, height: 2400)
let fitted = fittedDeviceRect(devicePixels: dev, container: CGSize(width: 800, height: 600))
// scale = min(800/1080, 600/2400) = 0.25 → 270×600, centred horizontally.
expect(abs(fitted.width - 270) < 0.001 && abs(fitted.height - 600) < 0.001, "fittedDeviceRect scales to fit")
expect(abs(fitted.minX - 265) < 0.001 && abs(fitted.minY - 0) < 0.001, "fittedDeviceRect centres the letterbox")
// Centre of the fitted rect maps to the centre of the device.
let centre = devicePoint(CGPoint(x: fitted.midX, y: fitted.midY), fitted: fitted, devicePixels: dev)
expect(centre != nil && abs(centre!.x - 540) < 0.001 && abs(centre!.y - 1200) < 0.001,
       "devicePoint maps the centre to device centre")
// Top-left corner of the fitted rect → device (0,0).
let corner = devicePoint(CGPoint(x: fitted.minX, y: fitted.minY), fitted: fitted, devicePixels: dev)
expect(corner != nil && abs(corner!.x) < 0.001 && abs(corner!.y) < 0.001, "devicePoint maps the corner to (0,0)")
// A tap in the pillar-box margin (left of the fitted rect) is rejected, not clamped.
expectEqual(devicePoint(CGPoint(x: 10, y: 300), fitted: fitted, devicePixels: dev), nil,
            "devicePoint rejects a tap in the letterbox margin")
// Degenerate inputs never crash or divide by zero.
expectEqual(fittedDeviceRect(devicePixels: .zero, container: CGSize(width: 800, height: 600)), .zero,
            "fittedDeviceRect zero on zero device size")
expectEqual(devicePoint(.zero, fitted: .zero, devicePixels: dev), nil,
            "devicePoint nil on an empty fitted rect")

// MARK: ProcessRegistry — concurrent boot+stop bookkeeping

do {
    func sleeper(_ seconds: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = [seconds]
        try? p.run()
        return p
    }
    let p1 = sleeper("30")
    let p2 = sleeper("30")
    // A short-lived process we let finish, to prove pruning drops dead handles.
    let dead = Process()
    dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? dead.run()
    dead.waitUntilExit()

    expectEqual(ProcessRegistry.pruned([p1, p2, dead]).count, 2,
                "ProcessRegistry.pruned drops finished processes")
    let signalled = ProcessRegistry.terminateRunning([p1, p2, dead])
    expectEqual(signalled, 2, "ProcessRegistry.terminateRunning signals only the live ones")
    p1.waitUntilExit(); p2.waitUntilExit()
    expectEqual(ProcessRegistry.pruned([p1, p2]).count, 0,
                "ProcessRegistry.pruned is empty after terminate+reap")
}

// MARK: result

if failures > 0 {
    print("\n✗ \(failures) failure(s)")
    exit(1)
}
print("\n✓ all unit tests passed")
