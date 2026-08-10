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

    /// One item from the audio stream. `unavailable` is terminal — the device
    /// reported it can't capture (see `ScrcpyAudioMeta`), and no PCM follows.
    /// `pcm` payloads are raw s16le/48 kHz/stereo interleaved samples.
    public enum AudioEvent: Sendable {
        case unavailable
        case pcm(Data)
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
    private var audioSocketFD: Int32 = -1
    private var controlSocketFD: Int32 = -1
    private var forwardedPort: Int?

    /// Every control-socket write goes through this one serial queue. Touch
    /// events arrive as a rapid down→move→…→up burst, and the device's gesture
    /// and velocity tracking only make sense if it reads them in that exact
    /// order; a serial queue guarantees it, and also stops two writes
    /// interleaving mid-message on the shared fd. (The old path fired each event
    /// on its own `Task.detached`, which guaranteed neither — edge swipes like
    /// the pull-down shade and the home-bar-up gesture were the casualties.)
    private let controlQueue = DispatchQueue(label: "com.cver.andross.scrcpy.control", qos: .userInteractive)

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
        //
        // With audio enabled the server accepts three sockets in a fixed order —
        // video, then audio, then control — and assigns them by that order, so
        // we must connect in exactly that sequence. The audio socket always
        // connects (it's opened whenever audio is *requested*); whether real
        // audio follows is read off the socket itself in readAudioLoop.
        guard let videoFD = await connectWithRetry(port: port),
              let audioFD = await connectWithRetry(port: port),
              let controlFD = await connectWithRetry(port: port) else {
            Ln.warn("scrcpy: could not connect video/audio/control sockets")
            stop()
            return nil
        }
        videoSocketFD = videoFD
        audioSocketFD = audioFD
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
        if audioSocketFD >= 0 { Darwin.close(audioSocketFD); audioSocketFD = -1 }
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
            "audio=true",
            // Raw PCM (s16le/48k/stereo): no decoder to bundle, and the extra
            // bandwidth is nothing over a localhost adb tunnel. Audio failure is
            // non-fatal by default (require_audio stays false), so a device that
            // can't capture just streams video.
            "audio_codec=raw",
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

    // MARK: - Audio read loop

    /// Begin reading the audio socket, if one connected. Returns nil when audio
    /// was never wired up; otherwise the stream's first event may still be
    /// `.unavailable` if the device can't capture. Call once, after `start()`.
    public func makeAudioStream() -> AsyncStream<AudioEvent>? {
        guard audioSocketFD >= 0 else { return nil }
        let fd = audioSocketFD
        return AsyncStream<AudioEvent> { continuation in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.readAudioLoop(fd: fd, continuation: continuation)
            }
        }
    }

    private func readAudioLoop(fd: Int32, continuation: AsyncStream<AudioEvent>.Continuation) async {
        // Leading 4-byte codec id — or a sentinel meaning "no audio here".
        guard let metaBytes = readExactly(fd: fd, count: 4),
              let meta = AndrossParse.scrcpyAudioMeta(from: [UInt8](metaBytes)) else {
            continuation.finish(); return
        }
        switch meta {
        case .disabled, .configError:
            Ln.warn("scrcpy: device reports no audio (\(meta)); streaming video only")
            continuation.yield(.unavailable)
            continuation.finish()
            return
        case .codec(let id):
            guard id == AndrossParse.scrcpyAudioCodecRaw else {
                Ln.warn("scrcpy: unexpected audio codec \(AndrossParse.scrcpyCodecName(from: id)); no audio")
                continuation.yield(.unavailable)
                continuation.finish()
                return
            }
        }

        // Same 12-byte frame header as video; raw sends no config packet, but a
        // config-flagged packet (were one ever to appear) carries no PCM to play.
        while true {
            guard let headerData = readExactly(fd: fd, count: 12),
                  let header = AndrossParse.scrcpyFrameHeader(from: [UInt8](headerData)) else {
                break
            }
            guard header.packetSize > 0 else { continue }
            guard let payload = readExactly(fd: fd, count: header.packetSize) else { break }
            if header.isConfig { continue }
            continuation.yield(.pcm(payload))
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

    // MARK: - Control messages (fire-and-forget, serialised writes)

    /// Enqueue a control message. Returns immediately; the actual socket write
    /// runs on `controlQueue`, so callers never block the UI thread and — more
    /// importantly — a burst of events keeps the order it was enqueued in (see
    /// `controlQueue`). Enqueue from one thread (the main actor, as the input
    /// handlers do) and the device sees the events in exactly that order.
    private func sendControl(_ bytes: [UInt8]) {
        controlQueue.async { [weak self] in
            guard let self, self.controlSocketFD >= 0 else { return }
            var offset = 0
            bytes.withUnsafeBytes { ptr in
                while offset < bytes.count {
                    let n = Darwin.write(self.controlSocketFD, ptr.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }
    }

    public func sendTouch(action: ScrcpyControl.TouchAction, x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16, pressure: Float = 1.0) {
        sendControl(ScrcpyControl.touchEvent(action: action, x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight, pressure: pressure))
    }

    public func sendKeycode(action: ScrcpyControl.KeyAction, keycode: Int32) {
        sendControl(ScrcpyControl.keycodeEvent(action: action, keycode: keycode))
    }

    /// Type `text` on the phone. Picks the wire path that can actually carry it
    /// (see `ScrcpyControl.textInjection`) — callers don't need to know that
    /// Android can't key-event its way to a CJK character.
    public func sendText(_ text: String) {
        sendControl(ScrcpyControl.textInjection(text))
    }

    public func sendBackOrScreenOn(action: ScrcpyControl.KeyAction) {
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
    public func sendScroll(x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16, hScroll: Float, vScroll: Float) {
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
    static let serverName = "scrcpy-server"

    /// The places the resource bundle may legitimately sit. Shared with `verifyResources()` so the
    /// diagnostic can never list a different set of paths than the one actually searched.
    static func serverSearchBases() -> [URL] {
        let bundleName = "andross_AndrossCore.bundle"
        return [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),  // .app/Contents/Resources
            Bundle.main.bundleURL.appendingPathComponent(bundleName),     // swift run, tests
            Bundle.main.resourceURL,                                      // resources copied in flat
        ].compactMap { $0 }
    }

    static func bundledServerURL() -> URL? {
        for base in serverSearchBases() {
            let jar = base.appendingPathComponent(serverName)
            if FileManager.default.fileExists(atPath: jar.path) { return jar }
        }
        return nil
    }

    /// `andross --verify-resources` — answers, from wherever the binary is installed, whether the
    /// app can find and trust its own vendored server.
    ///
    /// This exists so the build script stops asserting a path of its own choosing. That check can
    /// only ever confirm that the copy it just made landed where it aimed; it cannot notice that
    /// the app looks somewhere else, because the two paths have different authors and nothing
    /// reconciles them. (marktile's Mac host had exactly that gap: its build check was green for
    /// months while the app was quietly reading its engine out of a developer's .build directory.)
    /// Running the shipped binary's own lookup makes the check's subject the code.
    public static func verifyResources() -> Int32 {
        guard let url = bundledServerURL() else {
            FileHandle.standardError.write(Data("✗ andross cannot find its vendored scrcpy-server. Tried:\n".utf8))
            for base in serverSearchBases() {
                FileHandle.standardError.write(Data("    \(base.appendingPathComponent(serverName).path)\n".utf8))
            }
            return 1
        }
        guard verifyBundledServerChecksum() else {
            FileHandle.standardError.write(Data("✗ scrcpy-server found at \(url.path) but its checksum does not match.\n".utf8))
            return 1
        }
        print("✓ scrcpy-server: \(url.path)")
        return 0
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
