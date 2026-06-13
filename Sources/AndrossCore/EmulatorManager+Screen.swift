import Foundation

// MARK: - Embedded screen: frame capture + input injection
//
// Lets the app show the phone inside its own window (emulator runs
// headless) instead of a separate emulator window. Transport is a single
// persistent `adb exec-out` shell that streams raw RGBA frames (see
// `streamScreen`); `captureScreen` remains for one-shot grabs. A future
// h264 scrcpy-style encoder could cut bandwidth without changing this API.

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
        let (status, data) = Shell.runData([adbPath, "-s", serial, "exec-out", "screencap"])
        guard status == 0, data.count > 12 else { return nil }
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

    public struct ScreenFrame: Sendable {
        public let width: Int
        public let height: Int
        public let pixelData: Data
    }

    /// Stream screen frames asynchronously from a persistent ADB shell loop.
    /// Spawns exactly one ADB process and streams raw RGBA frames at ~60 FPS.
    public func streamScreen(serial: String) -> AsyncStream<ScreenFrame> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [adbPath, "-s", serial, "exec-out", "while true; do screencap; usleep 16666; done"]
            
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env

            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                continuation.finish()
                return
            }

            continuation.onTermination = { @Sendable _ in
                if process.isRunning {
                    process.terminate()
                }
            }

            Task.detached(priority: .userInitiated) {
                let fileHandle = outPipe.fileHandleForReading
                
                func readExactly(count: Int) -> Data? {
                    var buffer = Data()
                    while buffer.count < count {
                        let needed = count - buffer.count
                        do {
                            guard let chunk = try fileHandle.read(upToCount: needed), !chunk.isEmpty else {
                                return nil
                            }
                            buffer.append(chunk)
                        } catch {
                            return nil
                        }
                    }
                    return buffer
                }

                while process.isRunning {
                    guard let header = readExactly(count: 12) else { break }
                    let w = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                    let h = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
                    let width = Int(w)
                    let height = Int(h)

                    guard width > 0, height > 0 else { break }

                    let pixelBytes = width * height * 4
                    guard let pixelData = readExactly(count: pixelBytes) else { break }

                    let frame = ScreenFrame(width: width, height: height, pixelData: pixelData)
                    continuation.yield(frame)
                }

                if process.isRunning {
                    process.terminate()
                }
                continuation.finish()
            }
        }
    }
}
