import Foundation

// MARK: - Embedded screen: frame capture + input injection
//
// Lets the app show the phone inside its own window (emulator runs
// headless) instead of a separate emulator window. MVP transport is
// `screencap` polling — a few fps, fine for messengers; a low-latency
// scrcpy-style stream can replace it without changing this API.

extension EmulatorManager {
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

    /// Type text into the focused field (spaces handled via %s encoding).
    @discardableResult
    public func inputText(serial: String, _ text: String) -> Bool {
        let encoded = text.replacingOccurrences(of: " ", with: "%s")
        return adb(serial, ["shell", "input", "text", encoded]).ok
    }
}
