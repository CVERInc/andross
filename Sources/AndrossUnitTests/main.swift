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

// MARK: scrcpy text injection (INJECT_TEXT vs SET_CLIPBOARD)

// ASCII rides INJECT_TEXT (type 1): 4-byte length, then the UTF-8 bytes.
let asciiInjection = ScrcpyControl.textInjection("hi")
expectEqual(asciiInjection, [1, 0, 0, 0, 2, 0x68, 0x69],
            "textInjection sends ASCII as INJECT_TEXT")

// CJK cannot be key-evented on the device, so it must go out as SET_CLIPBOARD
// (type 9) with the paste flag — landing "123" out of "測試123" is the bug this
// guards against.
let cjkInjection = ScrcpyControl.textInjection("測")
expectEqual(cjkInjection.first, 9, "textInjection sends non-ASCII as SET_CLIPBOARD, not INJECT_TEXT")
expectEqual(Array(cjkInjection[1...8]), [0, 0, 0, 0, 0, 0, 0, 0],
            "SET_CLIPBOARD carries an 8-byte sequence (0 = no ack wanted)")
expectEqual(cjkInjection[9], 1, "SET_CLIPBOARD sets the paste flag, so the phone pastes it immediately")
expectEqual(Array(cjkInjection[10...13]), [0, 0, 0, 3],
            "SET_CLIPBOARD's length is UTF-8 bytes (測 is 3), not characters")
expectEqual(Array(cjkInjection[14...]), Array("測".utf8),
            "SET_CLIPBOARD carries the text as UTF-8")

// Mixed text is only as typable as its worst character.
expectEqual(ScrcpyControl.textInjection("測試123").first, 9,
            "textInjection sends mixed CJK+ASCII over the clipboard — INJECT_TEXT would drop the CJK half")

// MARK: routeMacKey

expectEqual(routeMacKey(virtualKey: 0, characters: "測試123", commandHeld: false, clipboard: nil),
            .text("測試123"),
            "routeMacKey sends CJK straight through as text — no escaping, no keycode table")
expectEqual(routeMacKey(virtualKey: 53, characters: "\u{1B}", commandHeld: false, clipboard: nil),
            .keycode(4),
            "routeMacKey maps Escape to Android BACK")
expectEqual(routeMacKey(virtualKey: 51, characters: "\u{7F}", commandHeld: false, clipboard: nil),
            .keycode(67),
            "routeMacKey maps Backspace to Android DEL")
expectEqual(routeMacKey(virtualKey: 36, characters: "\r", commandHeld: false, clipboard: nil),
            .keycode(66),
            "routeMacKey maps Return to Android ENTER")
expectEqual(routeMacKey(virtualKey: 9, characters: "v", commandHeld: true, clipboard: "貼上的字"),
            .text("貼上的字"),
            "routeMacKey turns Cmd+V into the Mac clipboard's text — the phone's own clipboard isn't the one you copied from")
expectEqual(routeMacKey(virtualKey: 9, characters: "v", commandHeld: true, clipboard: ""),
            .ignore,
            "routeMacKey ignores Cmd+V with an empty clipboard")
expectEqual(routeMacKey(virtualKey: 12, characters: "q", commandHeld: true, clipboard: "x"),
            .ignore,
            "routeMacKey leaves other Command shortcuts (Cmd+Q) to macOS")
expectEqual(routeMacKey(virtualKey: 0, characters: "\u{1}", commandHeld: false, clipboard: nil),
            .ignore,
            "routeMacKey drops control characters rather than typing them")
expectEqual(routeMacKey(virtualKey: 0, characters: nil, commandHeld: false, clipboard: nil),
            .ignore,
            "routeMacKey ignores a key with no characters")

// MARK: embeddedScreenWindowSize

// A 720x1600 stream (the emulator's own 1080x2400, capped by max_size) inside
// an 800pt-long window: the screen takes the full 780pt between the bezels and
// the window's short edge follows from the device — no leftover bars either way,
// and no strip reserved for chrome (the island rides the status bar instead).
let portraitFit = embeddedScreenWindowSize(deviceAspect: 720.0 / 1600.0, longSide: 800)
expect(abs(portraitFit.screen.height - 780) < 0.001 && abs(portraitFit.screen.width - 351) < 0.001,
       "embeddedScreenWindowSize fills the long edge and derives the short one from the device")
expect(abs(portraitFit.window.height - 800) < 0.001 && abs(portraitFit.window.width - 371) < 0.001,
       "embeddedScreenWindowSize wraps the screen in a uniform bezel")
expect(abs(portraitFit.screen.width / portraitFit.screen.height - 0.45) < 0.001,
       "embeddedScreenWindowSize keeps the device's aspect exactly — the bar-free condition")

// Orientation follows the device, not the caller: a landscape stream turns the
// long edge into the width, so the window lies down with the phone.
let landscapeFit = embeddedScreenWindowSize(deviceAspect: 1600.0 / 720.0, longSide: 800)
expect(abs(landscapeFit.screen.width - 780) < 0.001 && abs(landscapeFit.screen.height - 351) < 0.001,
       "embeddedScreenWindowSize lays the screen down for a landscape stream")
expect(landscapeFit.window.width > landscapeFit.window.height,
       "embeddedScreenWindowSize gives a landscape stream a landscape window")

expectEqual(embeddedScreenWindowSize(deviceAspect: 0, longSide: 800).window, .zero,
            "embeddedScreenWindowSize rejects a zero aspect")
expectEqual(embeddedScreenWindowSize(deviceAspect: 0.45, longSide: 10).window, .zero,
            "embeddedScreenWindowSize rejects a window smaller than its own bezels")

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

// MARK: scrcpy video protocol parsing

expectEqual(AndrossParse.scrcpyCodecId(from: Array("h264".utf8)), 0x68_32_36_34,
            "scrcpyCodecId decodes the big-endian ASCII codec id")
expectEqual(AndrossParse.scrcpyCodecId(from: [0x68, 0x32]), nil,
            "scrcpyCodecId nil on a short header")
expectEqual(AndrossParse.scrcpyCodecName(from: 0x68_32_36_34), "h264",
            "scrcpyCodecName round-trips back to ASCII")

func sessionMetaBytes(flags: UInt32, width: UInt32, height: UInt32) -> [UInt8] {
    func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    return u32(flags) + u32(width) + u32(height)
}
let sessionMeta = AndrossParse.scrcpySessionMeta(from: sessionMetaBytes(flags: 0x8000_0001, width: 1080, height: 2400))
expect(sessionMeta?.width == 1080 && sessionMeta?.height == 2400 && sessionMeta?.isClientResize == true,
       "scrcpySessionMeta parses dimensions and the client-resize bit")
let sessionMetaNoResize = AndrossParse.scrcpySessionMeta(from: sessionMetaBytes(flags: 0x8000_0000, width: 1080, height: 2400))
expectEqual(sessionMetaNoResize?.isClientResize, false, "scrcpySessionMeta clears isClientResize when bit 0 is unset")
expectEqual(AndrossParse.scrcpySessionMeta(from: sessionMetaBytes(flags: 0, width: 0, height: 2400)), nil,
            "scrcpySessionMeta rejects a zero width")
expectEqual(AndrossParse.scrcpySessionMeta(from: [0, 0]), nil,
            "scrcpySessionMeta nil on a short header")

func frameHeaderBytes(ptsAndFlags: UInt64, packetSize: UInt32) -> [UInt8] {
    var bytes: [UInt8] = []
    for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((ptsAndFlags >> shift) & 0xff)) }
    bytes += [UInt8(packetSize >> 24), UInt8((packetSize >> 16) & 0xff), UInt8((packetSize >> 8) & 0xff), UInt8(packetSize & 0xff)]
    return bytes
}
let configFlag: UInt64 = 1 << 62
let keyFrameFlag: UInt64 = 1 << 61
let configHeader = AndrossParse.scrcpyFrameHeader(from: frameHeaderBytes(ptsAndFlags: configFlag, packetSize: 42))
expect(configHeader?.isConfig == true && configHeader?.pts == 0 && configHeader?.packetSize == 42,
       "scrcpyFrameHeader recognizes a config (SPS/PPS) packet with zero pts")
let keyFrameHeader = AndrossParse.scrcpyFrameHeader(from: frameHeaderBytes(ptsAndFlags: keyFrameFlag | 123_456, packetSize: 900))
expect(keyFrameHeader?.isConfig == false && keyFrameHeader?.isKeyFrame == true && keyFrameHeader?.pts == 123_456,
       "scrcpyFrameHeader strips the key-frame bit out of pts")
let plainFrameHeader = AndrossParse.scrcpyFrameHeader(from: frameHeaderBytes(ptsAndFlags: 999, packetSize: 10))
expect(plainFrameHeader?.isConfig == false && plainFrameHeader?.isKeyFrame == false && plainFrameHeader?.pts == 999,
       "scrcpyFrameHeader handles a plain (non-key) frame")
expectEqual(AndrossParse.scrcpyFrameHeader(from: frameHeaderBytes(ptsAndFlags: 0, packetSize: UInt32(AndrossParse.maxScrcpyPacketSize) + 1)), nil,
            "scrcpyFrameHeader rejects a packet size past the sanity ceiling")

// MARK: scrcpy audio codec meta (sentinels vs a real codec)

expectEqual(AndrossParse.scrcpyAudioMeta(from: [0, 0, 0, 0]), .disabled,
            "scrcpyAudioMeta reads codec id 0 as audio disabled by the device")
expectEqual(AndrossParse.scrcpyAudioMeta(from: [0, 0, 0, 1]), .configError,
            "scrcpyAudioMeta reads codec id 1 as a capture/config error")
expectEqual(AndrossParse.scrcpyAudioMeta(from: [0x00, 0x72, 0x61, 0x77]), .codec(id: AndrossParse.scrcpyAudioCodecRaw),
            "scrcpyAudioMeta reads the raw-PCM fourcc as a real codec")
expectEqual(AndrossParse.scrcpyAudioCodecRaw, AndrossParse.scrcpyCodecId(from: Array("\u{0}raw".utf8)),
            "the raw fourcc constant matches 'raw' right-aligned in four bytes")
expectEqual(AndrossParse.scrcpyAudioMeta(from: [0x6f, 0x70]), nil,
            "scrcpyAudioMeta nil on a short header")

var deviceNameBuf = [UInt8](repeating: 0, count: 64)
let nameBytes = Array("line-test".utf8)
deviceNameBuf.replaceSubrange(0..<nameBytes.count, with: nameBytes)
expectEqual(AndrossParse.scrcpyDeviceName(from: deviceNameBuf), "line-test",
            "scrcpyDeviceName stops at the NUL pad")
expectEqual(AndrossParse.scrcpyDeviceName(from: [UInt8](repeating: 0, count: 10)), nil,
            "scrcpyDeviceName nil on a short buffer")

// MARK: scrcpy control message serialization

let touchDown = ScrcpyControl.touchEvent(action: .down, x: 100, y: 200, screenWidth: 1080, screenHeight: 2400)
expectEqual(touchDown.count, 32, "touchEvent is 32 bytes (1 type + 1 action + 8 pointerId + 8 xy + 4 wh + 2 pressure + 4 + 4 buttons)")
expectEqual(touchDown[0], 2, "touchEvent leads with TYPE_INJECT_TOUCH_EVENT = 2")
expectEqual(touchDown[1], ScrcpyControl.TouchAction.down.rawValue, "touchEvent encodes the DOWN action")
// pointerId (8 bytes at offset 2): defaults to the generic-finger id (all-but-one bits set).
expectEqual(Array(touchDown[2..<10]), [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe],
            "touchEvent defaults to SC_POINTER_ID_GENERIC_FINGER, big-endian")
// x (int32 at offset 10) = 100
expectEqual(Array(touchDown[10..<14]), [0, 0, 0, 100], "touchEvent encodes x big-endian")
// layout after pointerId(2..10): x(10..14) y(14..18) screenW(18..20) screenH(20..22) pressure(22..24)
expectEqual(Array(touchDown[22..<24]), [0xff, 0xff], "touchEvent encodes full pressure as the reserved 0xFFFF")

let touchMove = ScrcpyControl.touchEvent(action: .move, pointerId: 7, x: -5, y: 0, screenWidth: 360, screenHeight: 800, pressure: 0)
expectEqual(Array(touchMove[10..<14]), [0xff, 0xff, 0xff, 0xfb], "touchEvent encodes a negative x as two's complement")
expectEqual(Array(touchMove[22..<24]), [0, 0], "touchEvent encodes zero pressure as 0x0000")

let keyDown = ScrcpyControl.keycodeEvent(action: .down, keycode: 66) // KEYCODE_ENTER
expectEqual(keyDown, [0, 0, 0, 0, 0, 66, 0, 0, 0, 0, 0, 0, 0, 0], "keycodeEvent encodes type+action+keycode+repeat+metaState")

let shortText = ScrcpyControl.textEvent("hi")
expectEqual(shortText, [1, 0, 0, 0, 2, UInt8(ascii: "h"), UInt8(ascii: "i")], "textEvent length-prefixes UTF-8 bytes")

let cjkText = ScrcpyControl.textEvent("測試123")
expectEqual(Array(cjkText.dropFirst(5)), Array("測試123".utf8), "textEvent passes CJK straight through as UTF-8")

let longText = String(repeating: "x", count: 500)
let truncated = ScrcpyControl.textEvent(longText)
expectEqual(truncated.count, 1 + 4 + 300, "textEvent truncates at 300 UTF-8 bytes, matching the reference client")

// A multi-byte UTF-8 sequence straddling the 300-byte cut must not be split mid-codepoint.
let straddling = String(repeating: "a", count: 299) + "測測測"
let truncatedStraddle = ScrcpyControl.textEvent(straddling)
let payload = Array(truncatedStraddle.dropFirst(5))
expect(String(bytes: payload, encoding: .utf8) != nil,
       "textEvent backs off the truncation point so it never splits a UTF-8 codepoint")

let backEvent = ScrcpyControl.backOrScreenOn(action: .down)
expectEqual(backEvent, [4, 0], "backOrScreenOn encodes TYPE_BACK_OR_SCREEN_ON + action")

// Layout: type(1) x(4) y(4) screenW(2) screenH(2) hScroll(2) vScroll(2) buttons(4) = 21 bytes.
let scroll = ScrcpyControl.scrollEvent(x: 50, y: 60, screenWidth: 1080, screenHeight: 2400, hScroll: 0, vScroll: 16)
expectEqual(scroll.count, 21, "scrollEvent is 21 bytes")
expectEqual(scroll[0], 3, "scrollEvent leads with TYPE_INJECT_SCROLL_EVENT = 3")
expectEqual(Array(scroll[13..<15]), [0, 0], "scrollEvent encodes zero hScroll as 0")
expectEqual(Array(scroll[15..<17]), [0x7f, 0xff], "scrollEvent clamps full-range vScroll to the max positive fixed-point value")

// MARK: H.264 Annex-B <-> AVCC conversion

let threeByteSC: [UInt8] = [0, 0, 1]
let fourByteSC: [UInt8] = [0, 0, 0, 1]
let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1f]
let pps: [UInt8] = [0x68, 0xce, 0x3c, 0x80]
let idrSlice: [UInt8] = [0x65, 0x88, 0x84, 0x00]

let configPacket = fourByteSC + sps + fourByteSC + pps
let configUnits = AndrossParse.splitAnnexBNALUnits(configPacket)
expectEqual(configUnits.count, 2, "splitAnnexBNALUnits finds both SPS and PPS in a config packet")
expectEqual(configUnits.first ?? [], sps, "splitAnnexBNALUnits extracts the SPS bytes exactly")
expectEqual(configUnits.last ?? [], pps, "splitAnnexBNALUnits extracts the PPS bytes exactly")
expectEqual(AndrossParse.h264NALUnitType(configUnits[0]), 7, "h264NALUnitType recognizes SPS (7)")
expectEqual(AndrossParse.h264NALUnitType(configUnits[1]), 8, "h264NALUnitType recognizes PPS (8)")

let mixedStartCodes = threeByteSC + idrSlice
let mixedUnits = AndrossParse.splitAnnexBNALUnits(mixedStartCodes)
expectEqual(mixedUnits, [idrSlice], "splitAnnexBNALUnits handles a 3-byte start code")
expectEqual(AndrossParse.h264NALUnitType(idrSlice), 5, "h264NALUnitType recognizes an IDR slice (5)")

expectEqual(AndrossParse.splitAnnexBNALUnits([]), [], "splitAnnexBNALUnits nil-safe on empty input")
expectEqual(AndrossParse.splitAnnexBNALUnits([0, 0, 0]), [], "splitAnnexBNALUnits returns nothing without a real start code")

let avcc = AndrossParse.nalUnitsToAVCC([sps, pps])
let expectedAVCC: [UInt8] = [0, 0, 0, 4] + sps + [0, 0, 0, 4] + pps
expectEqual(avcc, expectedAVCC, "nalUnitsToAVCC prefixes each unit with its own 4-byte big-endian length")

// Round-trip: split an AVCC-style buffer's Annex-B source, convert back, get the same bytes.
let roundTrip = AndrossParse.nalUnitsToAVCC(AndrossParse.splitAnnexBNALUnits(configPacket))
expectEqual(roundTrip, expectedAVCC, "Annex-B -> split -> AVCC round-trips to the same length-prefixed form")

expectEqual(AndrossParse.h264NALUnitType([]), nil, "h264NALUnitType nil on an empty unit")

// MARK: result

if failures > 0 {
    print("\n✗ \(failures) failure(s)")
    exit(1)
}
print("\n✓ all unit tests passed")
