import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import AndrossCore

/// Hardware H.264 decode + display for the embedded screen, replacing the
/// old `Image(nsImage:)` + raw-RGBA-CGImage-per-frame path (~2fps, all-CPU).
/// Owns an `AVSampleBufferDisplayLayer`; callers feed it raw scrcpy video
/// packets (Annex-B, as the wire delivers them) via `handle(configPacket:)`
/// and `enqueue(frame:)` — the Annex-B/AVCC conversion itself is pure code
/// in AndrossCore (unit-tested); this file is only the AVFoundation-specific
/// wiring that can't be tested without a real decoder.
final class ScrcpyDisplayView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?
    private var frameCounter: Int64 = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        displayLayer.videoGravity = .resizeAspect
        root.addSublayer(displayLayer)
        layer = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    /// Resets decode state — call when the video session restarts (new
    /// ScrcpyClient connection) so a stale format description from a
    /// previous session/resolution never leaks into a new one.
    func reset() {
        formatDescription = nil
        frameCounter = 0
        displayLayer.flush()
    }

    /// Builds the `CMVideoFormatDescription` from an SPS/PPS config packet.
    /// Must succeed before any `enqueue(frame:)` call can do anything.
    func handle(configPacket data: Data) {
        let units = AndrossParse.splitAnnexBNALUnits([UInt8](data))
        guard units.count >= 2 else {
            Self.warn("config packet had \(units.count) NAL units, expected >= 2 (SPS+PPS)")
            return
        }
        // SPS is type 7, PPS is type 8 — pick by type rather than assuming
        // position, in case the encoder ever orders them differently.
        guard let sps = units.first(where: { AndrossParse.h264NALUnitType($0) == 7 }),
              let pps = units.first(where: { AndrossParse.h264NALUnitType($0) == 8 }) else {
            Self.warn("config packet missing SPS or PPS")
            return
        }

        let newDescription = Self.withPointers([sps, pps]) { pointers, sizes -> CMVideoFormatDescription? in
            var description: CMVideoFormatDescription?
            let status = pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &description
                    )
                }
            }
            return status == noErr ? description : nil
        }

        guard let newDescription else {
            Self.warn("CMVideoFormatDescriptionCreateFromH264ParameterSets failed")
            return
        }
        formatDescription = newDescription
        displayLayer.flush()
        frameCounter = 0
    }

    /// Enqueues one coded frame (Annex-B, as received) for immediate
    /// display. No-ops silently if the format description isn't ready yet
    /// (a frame arriving before its config packet — shouldn't happen given
    /// the server always writes the header first, but must never crash).
    func enqueue(frame data: Data, isKeyFrame: Bool) {
        guard let formatDescription else { return }
        let units = AndrossParse.splitAnnexBNALUnits([UInt8](data))
        guard !units.isEmpty else { return }
        let avcc = AndrossParse.nalUnitsToAVCC(units)

        guard let blockBuffer = Self.makeBlockBuffer(avcc) else { return }

        frameCounter += 1
        // displayImmediately (set below) ignores this for scheduling — it
        // only needs to be a valid, monotonically increasing CMTime so
        // CMSampleBufferCreateReady succeeds.
        let pts = CMTime(value: frameCounter, timescale: 90_000)
        var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?

        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachmentsArray) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKeyFrame {
                CFDictionarySetValue(dict,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    // MARK: - Helpers

    private static func makeBlockBuffer(_ bytes: [UInt8]) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = bytes.withUnsafeBytes { ptr -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }
        return blockBuffer
    }

    /// Recursively nests `withUnsafeBufferPointer` over each byte array so
    /// all pointers stay valid for the duration of `body` — the standard
    /// safe pattern for building an "array of unsafe pointers" argument.
    private static func withPointers<R>(_ arrays: [[UInt8]], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        func step(_ index: Int, _ pointers: [UnsafePointer<UInt8>]) -> R {
            if index == arrays.count {
                return body(pointers, arrays.map { $0.count })
            }
            return arrays[index].withUnsafeBufferPointer { buffer in
                step(index + 1, pointers + [buffer.baseAddress!])
            }
        }
        return step(0, [])
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write("[Andross] [WARN] scrcpy display: \(message)\n".data(using: .utf8)!)
    }
}

/// SwiftUI wrapper for `ScrcpyDisplayView`.
struct ScrcpyVideoView: NSViewRepresentable {
    let displayView: ScrcpyDisplayView

    func makeNSView(context: Context) -> ScrcpyDisplayView { displayView }
    func updateNSView(_ nsView: ScrcpyDisplayView, context: Context) {}
}
