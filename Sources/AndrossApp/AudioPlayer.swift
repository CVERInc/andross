import AVFoundation
import Foundation

/// Plays the phone's audio: raw PCM off the scrcpy audio socket, straight out
/// the Mac's speakers.
///
/// The stream is scrcpy's `raw` codec — s16le, 48 kHz, stereo, interleaved —
/// so there is nothing to decode. Each packet becomes an `AVAudioPCMBuffer`
/// scheduled on an `AVAudioPlayerNode`, which is itself the jitter buffer: it
/// plays scheduled buffers back to back and simply idles if the network hands
/// it nothing, resuming the instant the next packet arrives. A localhost adb
/// tunnel delivers packets steadily enough that this rarely shows.
///
/// This lives on the app side, not in AndrossCore, because AVAudioEngine is a
/// UI-layer concern and Core stays free of AVFoundation. Everything degrades
/// quietly: a failed engine start logs once and leaves the screen untouched,
/// mirroring how a missing scrcpy server degrades video to a poster.
final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var running = false

    /// Bytes per interleaved stereo s16 frame: 2 channels × 2 bytes.
    private static let bytesPerFrame = 4

    init?() {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: 48_000,
                                      channels: 2,
                                      interleaved: true) else {
            return nil
        }
        format = fmt
    }

    /// Bring the engine up and start pulling. Safe to call once; a second call
    /// is a no-op. The mixer converts our int16 format to whatever the output
    /// device wants, so we never touch the hardware format ourselves.
    ///
    /// Driven from the single audio-reading task so start, `enqueue`, and `stop`
    /// all run on one executor — `scheduleBuffer` is thread-safe, but the engine
    /// lifecycle calls prefer a consistent caller.
    func start() {
        guard !running else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.play()
            running = true
        } catch {
            log("engine failed to start: \(error.localizedDescription); no audio")
        }
    }

    /// Queue one raw-PCM packet for playback. Thread-safe — called from the
    /// socket-reading task, not the main actor. Drops silently before `start()`
    /// or after `stop()`, and ignores a partial trailing frame.
    func enqueue(_ pcm: Data) {
        guard running else { return }
        let frames = pcm.count / Self.bytesPerFrame
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        // Interleaved int16: a single channel buffer holds L,R,L,R… so one
        // memcpy of whole frames lands the samples verbatim.
        if let dst = buffer.int16ChannelData {
            pcm.withUnsafeBytes { src in
                if let base = src.baseAddress {
                    memcpy(dst[0], base, frames * Self.bytesPerFrame)
                }
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Tear the engine down and release the audio device. Safe to call more
    /// than once.
    func stop() {
        guard running else { return }
        running = false
        player.stop()
        engine.stop()
        engine.reset()
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("[Andross] [WARN] audio: \(message)\n".data(using: .utf8)!)
    }
}
