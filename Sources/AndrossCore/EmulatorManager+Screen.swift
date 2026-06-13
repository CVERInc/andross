import Foundation

// MARK: - Embedded screen: frame capture + input injection
//
// Lets the app show the phone inside its own window (emulator runs
// headless) instead of a separate emulator window. MVP transport is
// `screencap` polling — a few fps, fine for messengers; a low-latency
// scrcpy-style stream can replace it without changing this API.

extension EmulatorManager {
    /// Package of the window currently focused on the device.
    public func foregroundPackage(serial: String) -> String? {
        let result = adb(serial, ["shell", "dumpsys window | grep -m1 mCurrentFocus"])
        guard result.ok else { return nil }
        return AndrossParse.focusedPackage(from: result.stdout)
    }

    /// Package of the device's default launcher (the surface the thin shell
    /// deliberately never shows).
    public func defaultLauncherPackage(serial: String) -> String? {
        let result = adb(serial, ["shell", "cmd", "package", "resolve-activity", "--brief",
                                  "-a", "android.intent.action.MAIN",
                                  "-c", "android.intent.category.HOME"])
        guard result.ok else { return nil }
        return AndrossParse.launcherPackage(from: result.stdout)
    }

    /// Grab one PNG frame of the device's screen. Returns nil while the
    /// device is still booting or when capture fails.
    public func captureScreen(serial: String) -> Data? {
        let (status, data) = Shell.runData([adbPath, "-s", serial, "exec-out", "screencap", "-p"])
        guard status == 0, data.count > 8 else { return nil }
        // PNG magic: 89 50 4E 47
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        guard data.prefix(4).elementsEqual(magic) else { return nil }
        return data
    }

    /// Send a tap at device pixel coordinates.
    @discardableResult
    public func inputTap(serial: String, x: Int, y: Int) -> Bool {
        adb(serial, ["shell", "input", "tap", "\(x)", "\(y)"]).ok
    }

    /// Send a swipe between device pixel coordinates.
    @discardableResult
    public func inputSwipe(serial: String, fromX: Int, fromY: Int,
                           toX: Int, toY: Int, durationMs: Int = 200) -> Bool {
        adb(serial, ["shell", "input", "swipe",
                     "\(fromX)", "\(fromY)", "\(toX)", "\(toY)", "\(durationMs)"]).ok
    }

    /// Android key codes used by the navigation bar.
    public enum AndroidKey: Int, Sendable {
        case back = 4
        case home = 3
        case appSwitch = 187
        case power = 26
    }

    /// Send a navigation/system key.
    @discardableResult
    public func inputKey(serial: String, key: AndroidKey) -> Bool {
        adb(serial, ["shell", "input", "keyevent", "\(key.rawValue)"]).ok
    }

    /// Send a generic keyevent code.
    @discardableResult
    public func inputKeyevent(serial: String, keycode: Int) -> Bool {
        adb(serial, ["shell", "input", "keyevent", "\(keycode)"]).ok
    }

    /// Type text into the focused field (spaces handled via %s encoding, metacharacters escaped).
    @discardableResult
    public func inputText(serial: String, _ text: String) -> Bool {
        var escaped = ""
        for char in text {
            if char == " " {
                escaped += "%s"
            } else if "$`\"\\!*&|;<>(')".contains(char) {
                escaped += "\\\(char)"
            } else {
                escaped.append(char)
            }
        }
        return adb(serial, ["shell", "input", "text", escaped]).ok
    }
}
