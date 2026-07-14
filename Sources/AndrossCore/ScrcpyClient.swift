import Foundation
import Darwin
import CryptoKit

// MARK: - scrcpy transport
//
// Pushes the vendored scrcpy-server (Third-Party/scrcpy) to the device,
// forwards a local TCP port to its abstract socket, spawns the server via
// `app_process`, and speaks the video+control protocol decoded/encoded in
// ScrcpyProtocol.swift. Replaces the old `adb exec-out screencap` polling
// loop (~2fps) with real H.264 streaming and live touch injection.
//
// Any failure anywhere in `start()` — push, forward, spawn, handshake —
// returns nil rather than throwing: the caller falls back to the existing
// single-shot `captureScreen` poster (see EmulatorManager+Screen.swift),
// so a bad/missing server never blanks or crashes the embedded screen.

public final class ScrcpyClient: @unchecked Sendable {
    public struct VideoFrame: Sendable {
        public let isConfig: Bool
        public let isKeyFrame: Bool
        public let pts: UInt64
        public let data: Data
    }

    /// One item from the video stream: either the capture resolution
    /// (sent once at session start, and again on a server-side reset e.g.
    /// rotation) or a coded video packet. Carried in the same stream —
    /// rather than a separately-read property — so there's no race between
    /// a background reader thread writing it and the UI thread reading it.
    public enum VideoEvent: Sendable {
        case sessionMeta(width: Int, height: Int)
        case frame(VideoFrame)
    }

    /// SHA-256 of the vendored server jar (Third-Party/scrcpy/NOTICE.md),
    /// checked before every push — a corrupted or tampered resource must
    /// degrade to the poster fallback, never run silently.
    private static let expectedServerSHA256 =
        "84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a"

    private static let clientVersion = "4.0"
    private static let devicePushPath = "/data/local/tmp/andross-scrcpy-server.jar"

    private let serial: String
    private let scid: UInt32
    private let socketName: String

    private var serverProcess: Process?
    private var videoSocketFD: Int32 = -1
    private var controlSocketFD: Int32 = -1
    private var forwardedPort: Int?

    public private(set) var deviceName: String?

    public init(serial: String) {
        self.serial = serial
        self.scid = UInt32.random(in: 0..<0x7FFF_FFFF)
        self.socketName = String(format: "scrcpy_%08x", scid)
    }

    // MARK: - Lifecycle

    /// Full handshake: verify+push the server, forward a port, spawn the
    /// server process, connect video+control sockets, read the dummy byte
    /// and device name. Returns nil on any failure (see file header).
    public func start() async -> AsyncStream<VideoEvent>? {
        guard Self.verifyBundledServerChecksum() else {
            Ln.warn("scrcpy: bundled server checksum mismatch, refusing to run it")
            return nil
        }
        guard let jarURL = Self.bundledServerURL() else {
            Ln.warn("scrcpy: bundled server resource not found")
            return nil
        }

        let em = EmulatorManager.shared
        let push = em.adb(serial, ["push", jarURL.path, Self.devicePushPath])
        guard push.ok else {
            Ln.warn("scrcpy: adb push failed: \(push.stderr)")
            return nil
        }

        let forward = em.adb(serial, ["forward", "tcp:0", "localabstract:\(socketName)"])
        guard forward.ok, let port = Int(forward.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            Ln.warn("scrcpy: adb forward failed: \(forward.stderr)")
            return nil
        }
        forwardedPort = port

        guard spawnServer() else {
            cleanupForward()
            return nil
        }
        // An immediate connect() can succeed at the adb-forward tunnel's
        // local side (queued) well before app_process/JVM has actually
        // started and the remote LocalServerSocket is ready to accept —
        // observed to result in the queued connection being torn down
        // (read() returns EOF) rather than blocking for real data.
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        // The server needs a moment to bind its LocalServerSocket after
        // app_process starts; retry the connect briefly rather than racing it.
        guard let videoFD = await connectWithRetry(port: port),
              let controlFD = await connectWithRetry(port: port) else {
            Ln.warn("scrcpy: could not connect video/control sockets")
            stop()
            return nil
        }
        videoSocketFD = videoFD
        controlSocketFD = controlFD

        // Dummy byte (always sent to the first-accepted socket, which is
        // video since we open video before control — see DesktopConnection
        // .open()'s accept order in the vendored server).
        var dummy: UInt8 = 0xFF
        let dummyRead = Darwin.read(videoFD, &dummy, 1)
        guard dummyRead == 1, dummy == 0 else {
            Ln.warn("scrcpy: dummy byte handshake failed")
            stop()
            return nil
        }

        guard let nameBytes = readExactly(fd: videoFD, count: 64) else {
            Ln.warn("scrcpy: device name read failed")
            stop()
            return nil
        }
        deviceName = AndrossParse.scrcpyDeviceName(from: [UInt8](nameBytes))

        return AsyncStream<VideoEvent> { continuation in
            let fd = videoFD
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.readVideoLoop(fd: fd, continuation: continuation)
            }
        }
    }

    /// Terminates the server process, closes both sockets, and removes the
    /// adb port forward. Safe to call more than once.
    public func stop() {
        if videoSocketFD >= 0 { Darwin.close(videoSocketFD); videoSocketFD = -1 }
        if controlSocketFD >= 0 { Darwin.close(controlSocketFD); controlSocketFD = -1 }
        if let process = serverProcess, process.isRunning {
            process.terminate()
        }
        serverProcess = nil
        cleanupForward()
    }

    private func cleanupForward() {
        guard let port = forwardedPort else { return }
        _ = EmulatorManager.shared.adb(serial, ["forward", "--remove", "tcp:\(port)"])
        forwardedPort = nil
    }

    // MARK: - Server process

    private func spawnServer() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: EmulatorManager.shared.adbPath)
        let options = [
            "scid=\(String(format: "%08x", scid))",
            "tunnel_forward=true",
            "video=true",
            "audio=false",
            "control=true",
            "cleanup=true",
            "video_codec=h264",
            "max_size=1600",
            "max_fps=60",
        ]
        process.arguments = ["-s", serial, "shell",
                             "CLASSPATH=\(Self.devicePushPath)", "app_process", "/",
                             "com.genymobile.scrcpy.Server", Self.clientVersion] + options
        // Nobody reads these; a Pipe() nobody drains would block the child
        // dead once adb/the server write enough to fill the kernel pipe
        // buffer (matches streamScreen's convention in EmulatorManager+Screen).
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Ln.warn("scrcpy: failed to spawn server: \(error.localizedDescription)")
            return false
        }
        serverProcess = process
        return true
    }

    // MARK: - Socket connect

    private func connectWithRetry(port: Int, attempts: Int = 25, delayMS: UInt64 = 100) async -> Int32? {
        for attempt in 0..<attempts {
            if let fd = connectSocket(port: port) {
                return fd
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: delayMS * 1_000_000)
            }
        }
        return nil
    }

    private func connectSocket(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    // MARK: - Video read loop

    private func readVideoLoop(fd: Int32, continuation: AsyncStream<VideoEvent>.Continuation) async {
        continuation.onTermination = { @Sendable [weak self] _ in
            self?.stop()
        }

        // Stream header: 4-byte codec id, then 12-byte session meta. Both
        // are present because we don't set send_stream_meta=false.
        guard readExactly(fd: fd, count: 4) != nil else { continuation.finish(); return }
        guard let sessionBytes = readExactly(fd: fd, count: 12),
              let session = AndrossParse.scrcpySessionMeta(from: [UInt8](sessionBytes)) else {
            continuation.finish()
            return
        }
        continuation.yield(.sessionMeta(width: session.width, height: session.height))

        while true {
            guard let headerData = readExactly(fd: fd, count: 12),
                  let header = AndrossParse.scrcpyFrameHeader(from: [UInt8](headerData)) else {
                break
            }
            guard header.packetSize > 0 else { continue }
            guard let payload = readExactly(fd: fd, count: header.packetSize) else { break }

            continuation.yield(.frame(VideoFrame(isConfig: header.isConfig, isKeyFrame: header.isKeyFrame,
                                                  pts: header.pts, data: payload)))
        }
        continuation.finish()
    }

    private func readExactly(fd: Int32, count: Int) -> Data? {
        var buffer = Data(capacity: count)
        var remaining = count
        var chunk = [UInt8](repeating: 0, count: min(count, 65536))
        while remaining > 0 {
            let toRead = min(remaining, chunk.count)
            let n = chunk.withUnsafeMutableBytes { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, toRead)
            }
            guard n > 0 else { return nil }
            buffer.append(chunk, count: n)
            remaining -= n
        }
        return buffer
    }

    // MARK: - Control messages (fire-and-forget writes)

    @discardableResult
    private func sendControl(_ bytes: [UInt8]) -> Bool {
        guard controlSocketFD >= 0 else { return false }
        var offset = 0
        return bytes.withUnsafeBytes { ptr -> Bool in
            while offset < bytes.count {
                let n = Darwin.write(controlSocketFD, ptr.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    @discardableResult
    public func sendTouch(action: ScrcpyControl.TouchAction, x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16, pressure: Float = 1.0) -> Bool {
        sendControl(ScrcpyControl.touchEvent(action: action, x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight, pressure: pressure))
    }

    @discardableResult
    public func sendKeycode(action: ScrcpyControl.KeyAction, keycode: Int32) -> Bool {
        sendControl(ScrcpyControl.keycodeEvent(action: action, keycode: keycode))
    }

    /// Type `text` on the phone. Picks the wire path that can actually carry it
    /// (see `ScrcpyControl.textInjection`) — callers don't need to know that
    /// Android can't key-event its way to a CJK character.
    @discardableResult
    public func sendText(_ text: String) -> Bool {
        sendControl(ScrcpyControl.textInjection(text))
    }

    @discardableResult
    public func sendBackOrScreenOn(action: ScrcpyControl.KeyAction) -> Bool {
        sendControl(ScrcpyControl.backOrScreenOn(action: action))
    }

    /// INJECT_SCROLL_EVENT. Correct on the wire and **not** what the embedded
    /// screen uses — do not reach for it without re-measuring.
    ///
    /// Injected as a mouse wheel into the emulator, scrolling up moves the list
    /// and scrolling down does nothing whatsoever; the encoded bytes were dumped
    /// and are symmetric (-16 encodes to 0x8000, +16 to 0x7fff), so the events
    /// leave here correct and the device acts on half of them. ScreenView scrolls
    /// by injecting a finger instead, which works in both directions and in apps
    /// that ignore a wheel entirely. Kept for protocol completeness, and because
    /// a real handset may well honour it.
    @discardableResult
    public func sendScroll(x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16, hScroll: Float, vScroll: Float) -> Bool {
        sendControl(ScrcpyControl.scrollEvent(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight, hScroll: hScroll, vScroll: vScroll))
    }

    // MARK: - Integrity

    /// Where the vendored scrcpy-server actually is — found by hand, because
    /// `Bundle.module` cannot be asked this question safely.
    ///
    /// SwiftPM's generated accessor looks in exactly two places (the executable's
    /// own directory and the absolute .build path of the machine that compiled
    /// it) and calls `fatalError` when it finds neither. Inside a .app, the first
    /// is the bundle root — so a released app that keeps its resources where
    /// Apple wants them, in Contents/Resources, crashes the moment the screen is
    /// opened, while the developer's copy works forever off the stale .build
    /// path. Looking for the file ourselves covers both layouts and, more to the
    /// point, returns nil instead of killing the app: a missing server is meant
    /// to degrade to a poster, not take the window down with it.
    static func bundledServerURL() -> URL? {
        let bundleName = "andross_AndrossCore.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),  // .app/Contents/Resources
            Bundle.main.bundleURL.appendingPathComponent(bundleName),     // swift run, tests
            Bundle.main.resourceURL,                                      // resources copied in flat
        ].compactMap { $0 }

        for base in candidates {
            let jar = base.appendingPathComponent("scrcpy-server")
            if FileManager.default.fileExists(atPath: jar.path) { return jar }
        }
        return nil
    }

    private static func verifyBundledServerChecksum() -> Bool {
        guard let url = bundledServerURL(),
              let data = try? Data(contentsOf: url) else { return false }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex == expectedServerSHA256
    }
}

/// Minimal logger — matches the `[Andross] [WARN]` style already printed
/// elsewhere (e.g. EmulatorManager's window-size warning) without pulling in
/// a logging dependency.
enum Ln {
    static func warn(_ message: String) {
        FileHandle.standardError.write("[Andross] [WARN] \(message)\n".data(using: .utf8)!)
    }
}
