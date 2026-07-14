import Foundation

// MARK: - scrcpy wire protocol (video stream parsing + control message writing)
//
// Pure, side-effect-free codec for the vendored scrcpy-server v4.0 protocol
// (see Third-Party/scrcpy). All multi-byte integers on this wire are
// big-endian (Java DataInputStream/ByteBuffer default), unlike the
// little-endian `screencap` header parsed elsewhere in this file. Kept
// separate from socket I/O so it can be unit-tested without a device.

extension AndrossParse {
    /// The scrcpy video stream's leading 4-byte codec identifier — the
    /// 4-character codec name as big-endian ASCII (e.g. "h264" ==
    /// 0x68_32_36_34). Present only when the server is started with the
    /// (default) `send_stream_meta=true`.
    public static func scrcpyCodecId(from bytes: [UInt8]) -> UInt32? {
        guard bytes.count >= 4 else { return nil }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    /// ASCII form of `scrcpyCodecId`, e.g. "h264".
    public static func scrcpyCodecName(from id: UInt32) -> String {
        let bytes: [UInt8] = [UInt8((id >> 24) & 0xff), UInt8((id >> 16) & 0xff), UInt8((id >> 8) & 0xff), UInt8(id & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A `writeSessionMeta` record: the device's capture resolution, sent
    /// once when the encoder session starts and again on every reset
    /// (rotation, client-driven resize).
    public struct ScrcpySessionMeta: Equatable, Sendable {
        public let isClientResize: Bool
        public let width: Int
        public let height: Int

        public init(isClientResize: Bool, width: Int, height: Int) {
            self.isClientResize = isClientResize
            self.width = width
            self.height = height
        }
    }

    /// Parse the 12-byte session-meta record (flags:4, width:4, height:4).
    /// Rejects zero/implausible dimensions the same way `screencapHeader`
    /// does, since a misparsed stream offset could otherwise hand a huge
    /// bogus size to the display layer.
    public static func scrcpySessionMeta(from bytes: [UInt8]) -> ScrcpySessionMeta? {
        guard bytes.count >= 12 else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        let flags = u32(0)
        let width = Int(u32(4))
        let height = Int(u32(8))
        guard width > 0, height > 0,
              width <= maxScreencapDimension, height <= maxScreencapDimension else { return nil }
        return ScrcpySessionMeta(isClientResize: flags & 1 != 0, width: width, height: height)
    }

    /// A `writeFrameMeta`/`writePacket` record: one video packet's header.
    /// `isConfig` packets carry SPS/PPS (Annex-B) instead of coded frame
    /// data and have no meaningful `pts`.
    public struct ScrcpyFrameHeader: Equatable, Sendable {
        public let isConfig: Bool
        public let isKeyFrame: Bool
        public let pts: UInt64
        public let packetSize: Int

        public init(isConfig: Bool, isKeyFrame: Bool, pts: UInt64, packetSize: Int) {
            self.isConfig = isConfig
            self.isKeyFrame = isKeyFrame
            self.pts = pts
            self.packetSize = packetSize
        }
    }

    private static let scrcpyFlagConfig: UInt64 = 1 << 62
    private static let scrcpyFlagKeyFrame: UInt64 = 1 << 61

    /// Largest single video packet we'll trust a header to declare. A
    /// desynced stream could otherwise ask us to buffer gigabytes; no real
    /// H.264 access unit from a phone-sized capture approaches 64MB.
    public static let maxScrcpyPacketSize = 64 * 1024 * 1024

    /// Parse the 12-byte frame header (ptsAndFlags:8, packetSize:4).
    public static func scrcpyFrameHeader(from bytes: [UInt8]) -> ScrcpyFrameHeader? {
        guard bytes.count >= 12 else { return nil }
        var ptsAndFlags: UInt64 = 0
        for i in 0..<8 { ptsAndFlags = (ptsAndFlags << 8) | UInt64(bytes[i]) }
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        let packetSize = u32(8)
        guard packetSize >= 0, packetSize <= maxScrcpyPacketSize else { return nil }
        let isConfig = (ptsAndFlags & scrcpyFlagConfig) != 0
        let isKeyFrame = (ptsAndFlags & scrcpyFlagKeyFrame) != 0
        let pts = ptsAndFlags & ~(scrcpyFlagConfig | scrcpyFlagKeyFrame)
        return ScrcpyFrameHeader(isConfig: isConfig, isKeyFrame: isKeyFrame, pts: pts, packetSize: packetSize)
    }

    /// Parse the fixed 64-byte device-name field sent once at connection
    /// start (`sendDeviceMeta`) — UTF-8, NUL-padded/truncated.
    public static func scrcpyDeviceName(from bytes: [UInt8]) -> String? {
        guard bytes.count >= 64 else { return nil }
        let nulIndex = bytes.prefix(64).firstIndex(of: 0) ?? 64
        return String(decoding: bytes[0..<nulIndex], as: UTF8.self)
    }
}

/// Control-message serialization — the andross side is always the client
/// (device runs the server), so we only ever *write* these, never parse
/// them; matches `ControlMessageReader`/`ControlMessage` in the vendored
/// scrcpy-server source (Third-Party/scrcpy) for v4.0.
public enum ScrcpyControl {
    /// SC_POINTER_ID_GENERIC_FINGER from the reference client — identifies
    /// this pointer as a synthetic finger rather than a mouse cursor
    /// (SC_POINTER_ID_MOUSE, all-ones) so multi-touch-aware apps see a
    /// normal touch, not a hover/mouse pointer.
    public static let pointerIdGenericFinger: UInt64 = UInt64(bitPattern: -2)

    public enum TouchAction: UInt8, Sendable {
        case down = 0
        case up = 1
        case move = 2
        case cancel = 3
    }

    public enum KeyAction: UInt8, Sendable {
        case down = 0
        case up = 1
    }

    private static func appendU16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }

    private static func appendI32(_ bytes: inout [UInt8], _ value: Int32) {
        let u = UInt32(bitPattern: value)
        bytes.append(UInt8((u >> 24) & 0xff))
        bytes.append(UInt8((u >> 16) & 0xff))
        bytes.append(UInt8((u >> 8) & 0xff))
        bytes.append(UInt8(u & 0xff))
    }

    private static func appendU32(_ bytes: inout [UInt8], _ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private static func appendU64(_ bytes: inout [UInt8], _ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> shift) & 0xff))
        }
    }

    /// Inverse of `Binary.u16FixedPointToFloat` on the server: encodes a
    /// [0, 1] float as unsigned 16-bit fixed point, with 0xFFFF reserved
    /// to mean exactly 1.0 (matching the server's decode special case).
    private static func encodeU16FixedPoint(_ value: Float) -> UInt16 {
        if value >= 1.0 { return 0xFFFF }
        if value <= 0.0 { return 0 }
        return UInt16((value * 65536.0).rounded())
    }

    /// TYPE_INJECT_TOUCH_EVENT (33 bytes on the wire).
    public static func touchEvent(
        action: TouchAction,
        pointerId: UInt64 = pointerIdGenericFinger,
        x: Int32, y: Int32,
        screenWidth: UInt16, screenHeight: UInt16,
        pressure: Float = 1.0,
        actionButton: Int32 = 0,
        buttons: Int32 = 0
    ) -> [UInt8] {
        var bytes: [UInt8] = [2, action.rawValue] // TYPE_INJECT_TOUCH_EVENT
        appendU64(&bytes, pointerId)
        appendI32(&bytes, x)
        appendI32(&bytes, y)
        appendU16(&bytes, screenWidth)
        appendU16(&bytes, screenHeight)
        appendU16(&bytes, encodeU16FixedPoint(pressure))
        appendI32(&bytes, actionButton)
        appendI32(&bytes, buttons)
        return bytes
    }

    /// TYPE_INJECT_KEYCODE. `keycode` is a standard Android `KeyEvent`
    /// constant (e.g. KEYCODE_ENTER = 66).
    public static func keycodeEvent(action: KeyAction, keycode: Int32, repeatCount: Int32 = 0, metaState: Int32 = 0) -> [UInt8] {
        var bytes: [UInt8] = [0, action.rawValue] // TYPE_INJECT_KEYCODE
        appendI32(&bytes, keycode)
        appendI32(&bytes, repeatCount)
        appendI32(&bytes, metaState)
        return bytes
    }

    /// TYPE_INJECT_TEXT. Truncated at 300 UTF-8 bytes on a UTF-8-safe
    /// boundary — the reference client truncates (not chunks) here too
    /// (SC_CONTROL_MSG_INJECT_TEXT_MAX_LENGTH), and no single keystroke or
    /// paste in andross's actual use approaches that length.
    public static func textEvent(_ text: String) -> [UInt8] {
        var utf8 = Array(text.utf8)
        if utf8.count > 300 {
            var cut = 300
            // Back off until we're not splitting a multi-byte UTF-8 sequence
            // (continuation bytes have the top two bits `10`).
            while cut > 0 && (utf8[cut] & 0xC0) == 0x80 { cut -= 1 }
            utf8 = Array(utf8.prefix(cut))
        }
        var bytes: [UInt8] = [1] // TYPE_INJECT_TEXT
        appendU32(&bytes, UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
        return bytes
    }

    /// TYPE_SET_CLIPBOARD (v4.0 layout: sequence, paste flag, then the string).
    ///
    /// `sequence` is the ack id the server echoes back; 0 asks for no ack, and
    /// nothing here waits for one.
    public static func setClipboardEvent(_ text: String, paste: Bool, sequence: UInt64 = 0) -> [UInt8] {
        var bytes: [UInt8] = [9] // TYPE_SET_CLIPBOARD
        appendU64(&bytes, sequence)
        bytes.append(paste ? 1 : 0)
        let utf8 = Array(text.utf8)
        appendU32(&bytes, UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
        return bytes
    }

    /// The bytes that put `text` on the phone — INJECT_TEXT when it can carry
    /// the text, SET_CLIPBOARD + paste when it can't.
    ///
    /// INJECT_TEXT looks like the obvious path for everything and quietly isn't:
    /// the server turns the string into key events through Android's
    /// `KeyCharacterMap`, which can only produce events for characters a
    /// keyboard could physically type. Anything it can't map — every CJK
    /// character — is dropped on the device with no error to the client. Typing
    /// "測試123" this way lands "123", which is exactly what andross did before.
    ///
    /// So non-ASCII goes over the clipboard with the paste flag set, the same
    /// route scrcpy's own client uses for it. The cost is the phone's clipboard,
    /// which this overwrites; the alternative is text that silently vanishes.
    public static func textInjection(_ text: String) -> [UInt8] {
        text.allSatisfy(\.isASCII) ? textEvent(text) : setClipboardEvent(text, paste: true)
    }

    /// TYPE_BACK_OR_SCREEN_ON — the reference client's Back key path
    /// (distinct from a plain keycode: also wakes the screen).
    public static func backOrScreenOn(action: KeyAction) -> [UInt8] {
        [4, action.rawValue] // TYPE_BACK_OR_SCREEN_ON
    }

    /// TYPE_INJECT_SCROLL_EVENT. `hScroll`/`vScroll` are in [-1, 1] and get
    /// the server's ×16 range expansion undone here to match encode
    /// (server multiplies the decoded value by 16, so we divide first).
    public static func scrollEvent(x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16, hScroll: Float, vScroll: Float, buttons: Int32 = 0) -> [UInt8] {
        var bytes: [UInt8] = [3] // TYPE_INJECT_SCROLL_EVENT
        appendI32(&bytes, x)
        appendI32(&bytes, y)
        appendU16(&bytes, screenWidth)
        appendU16(&bytes, screenHeight)
        func encodeSigned16(_ v: Float) -> UInt16 {
            let clamped = max(-1, min(1, v / 16))
            if clamped >= 1 { return 0x7fff }
            if clamped <= -1 { return UInt16(bitPattern: -0x8000) }
            return UInt16(bitPattern: Int16((clamped * 32768.0).rounded()))
        }
        appendU16(&bytes, encodeSigned16(hScroll))
        appendU16(&bytes, encodeSigned16(vScroll))
        appendI32(&bytes, buttons)
        return bytes
    }
}

// MARK: - H.264 Annex-B <-> AVCC conversion
//
// Android's MediaCodec (both the SPS/PPS config packet and every coded
// frame) emits Annex-B: NAL units separated by 00 00 01 / 00 00 00 01
// start codes. VideoToolbox/CMSampleBuffer instead expect AVCC: each NAL
// prefixed by its own 4-byte big-endian length, no start codes. Pure byte
// manipulation — kept here (not in the AVFoundation-dependent display
// layer) so it's unit-testable without CoreMedia.

extension AndrossParse {
    /// Split an Annex-B byte stream into individual NAL units (start codes
    /// stripped). Tolerates both 3-byte (00 00 01) and 4-byte
    /// (00 00 00 01) start codes, and a leading run of either.
    public static func splitAnnexBNALUnits(_ data: [UInt8]) -> [[UInt8]] {
        guard !data.isEmpty else { return [] }
        var markers: [(startCodePos: Int, contentPos: Int)] = []
        var i = 0
        while i + 2 < data.count {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                markers.append((i, i + 3))
                i += 3
                continue
            }
            if i + 3 < data.count, data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                markers.append((i, i + 4))
                i += 4
                continue
            }
            i += 1
        }
        guard !markers.isEmpty else { return [] }

        var units: [[UInt8]] = []
        for (index, marker) in markers.enumerated() {
            let end = index + 1 < markers.count ? markers[index + 1].startCodePos : data.count
            guard marker.contentPos < end else { continue }
            units.append(Array(data[marker.contentPos..<end]))
        }
        return units
    }

    /// Re-pack already-split NAL units into AVCC form: each unit prefixed
    /// by its own 4-byte big-endian length, concatenated with no start
    /// codes — the form `CMBlockBuffer`/`CMSampleBuffer` expect.
    public static func nalUnitsToAVCC(_ units: [[UInt8]]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let len = UInt32(unit.count)
            result.append(UInt8((len >> 24) & 0xff))
            result.append(UInt8((len >> 16) & 0xff))
            result.append(UInt8((len >> 8) & 0xff))
            result.append(UInt8(len & 0xff))
            result.append(contentsOf: unit)
        }
        return result
    }

    /// NAL unit "type" field — the low 5 bits of the header byte (first
    /// byte of the unit, after start code / length prefix removal).
    /// 7 = SPS, 8 = PPS, 5 = IDR (keyframe) slice, 1 = non-IDR slice.
    public static func h264NALUnitType(_ unit: [UInt8]) -> UInt8? {
        guard let first = unit.first else { return nil }
        return first & 0x1F
    }
}
