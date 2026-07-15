import SwiftUI
import AppKit
import AndrossCore
import Signet

/// AppKit interaction layer for the embedded screen. A plain SwiftUI gesture
/// can't be used here: the window is movable-by-background, and a mouse-down
/// on a non-control view starts a window drag instead of the gesture. This
/// NSView opts out of window dragging and reports live down/move/up points
/// in top-left coordinates (real per-move touch, not a deferred replay — see
/// `sendTouch...` below). It also intercepts key down events and forwards
/// them to the running virtual device.
private struct ScreenInteraction: NSViewRepresentable {
    let onDown: (_ point: CGPoint, _ viewSize: CGSize) -> Void
    let onMove: (_ point: CGPoint, _ viewSize: CGSize) -> Void
    let onUp: (_ point: CGPoint, _ viewSize: CGSize) -> Void
    let onScroll: (_ point: CGPoint, _ viewSize: CGSize, _ deltaX: CGFloat, _ deltaY: CGFloat) -> Void

    final class InteractionView: NSView {
        var onDown: ((CGPoint, CGSize) -> Void)?
        var onMove: ((CGPoint, CGSize) -> Void)?
        var onUp: ((CGPoint, CGSize) -> Void)?
        var onScroll: ((CGPoint, CGSize, CGFloat, CGFloat) -> Void)?
        private var tracking = false

        override var mouseDownCanMoveWindow: Bool { false }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        // The borderless window never becomes key, so every click arrives
        // as a "first mouse" — accept it or we'd never see any events.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            tracking = true
            onDown?(convert(event.locationInWindow, from: nil), bounds.size)
        }

        override func mouseDragged(with event: NSEvent) {
            guard tracking else { return }
            onMove?(convert(event.locationInWindow, from: nil), bounds.size)
        }

        override func mouseUp(with event: NSEvent) {
            guard tracking else { return }
            tracking = false
            onUp?(convert(event.locationInWindow, from: nil), bounds.size)
        }

        override func scrollWheel(with event: NSEvent) {
            // Pixel-precise devices (trackpad, Magic Mouse) report scrollingDelta
            // in points; a notched wheel reports lines, so scale those up to
            // something the phone will actually feel.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
            let deltaX = event.scrollingDeltaX * scale
            let deltaY = event.scrollingDeltaY * scale
            guard deltaX != 0 || deltaY != 0 else { return }
            // Not negated: macOS already flips the sign for "natural" scrolling,
            // so passing it through is what makes the phone follow the same
            // direction as the rest of the user's Mac.
            onScroll?(convert(event.locationInWindow, from: nil), bounds.size, deltaX, deltaY)
        }

        // No keyDown override here on purpose. This window is borderless, so
        // AppKit never lets it become key, and a view inside a window that is
        // never key is never sent keyDown — the override that used to live here
        // was called exactly zero times, which is why "click screen to type"
        // never typed anything. Keys are picked up by a local event monitor in
        // ScreenAppView instead (the app is frontmost, so the events do arrive;
        // they simply have no key window to be routed to).
    }

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onDown = onDown
        view.onMove = onMove
        view.onUp = onUp
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.onDown = onDown
        view.onMove = onMove
        view.onUp = onUp
        view.onScroll = onScroll
    }
}

/// The phone's screen, embedded in the andross window.
///
/// Streams over scrcpy (hardware H.264, real-time touch injection) via
/// `ScrcpyClient` + `ScrcpyDisplayView` — replacing the old `adb exec-out
/// screencap` polling loop (~2fps, deferred-swipe-only gestures, all-CPU
/// decode). Falls back to a static `captureScreen` poster if the scrcpy
/// handshake fails for any reason (see ScrcpyClient's file header).
struct ScreenAppView: View {
    @ObservedObject var model: AppModel

    @State private var displayView = ScrcpyDisplayView(frame: .zero)
    @State private var client: ScrcpyClient?
    @State private var audioPlayer: AudioPlayer?
    @State private var devicePixels: CGSize = .zero
    @State private var isStreaming = false
    @State private var posterImage: NSImage?
    @State private var keyMonitor: Any?
    /// Where the scroll gesture's finger currently rests, or nil when it's lifted.
    @State private var scrollFinger: CGPoint?
    @State private var scrollLift: DispatchWorkItem?

    /// Concentric with the window's own corner (the 55pt glass mask in
    /// configureWindow, not the 44pt content clip that sits further in): a
    /// screen inset by the bezel has to lose exactly the bezel from that radius,
    /// or the two curves run at different speeds and the phone reads as a
    /// squared-off sticker on a very round slab.
    private static let windowCornerRadius: CGFloat = 55
    private static let screenCornerRadius: CGFloat = windowCornerRadius - embeddedScreenBezel

    /// Falls back to the window's own aspect until scrcpy reports the real one,
    /// which keeps the first frames from being squeezed through a stale shape.
    private var screenAspect: CGFloat {
        guard devicePixels.width > 0, devicePixels.height > 0 else {
            return max(model.currentWidth, 1) / max(model.currentHeight, 1)
        }
        return devicePixels.width / devicePixels.height
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if model.activeSerial == nil {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.slateTextDim)
                        Text("No phone is running.")
                            .font(.caption)
                            .foregroundStyle(Color.slateTextDim)
                    }
                    Spacer()
                } else if isStreaming {
                    // `aspectRatio` (not a plain fill) makes this view's frame the
                    // video's own rect, so the clip and the border land on the
                    // screen's edges instead of on a pane the video is letterboxed
                    // inside. With the window already shaped to the stream, the fit
                    // is exact and nothing is left over; if the two ever disagree
                    // for a frame — a rotation, a resize mid-stream — the border
                    // still hugs the phone rather than floating off in the margin.
                    GeometryReader { geo in
                        ScrcpyVideoView(displayView: displayView)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .overlay(
                                ScreenInteraction(
                                    onDown: { point, viewSize in sendTouch(.down, at: point, in: viewSize) },
                                    onMove: { point, viewSize in sendTouch(.move, at: point, in: viewSize) },
                                    onUp: { point, viewSize in sendTouch(.up, at: point, in: viewSize) },
                                    onScroll: { point, viewSize, dx, dy in
                                        sendScroll(at: point, in: viewSize, deltaX: dx, deltaY: dy)
                                    }
                                )
                            )
                    }
                    .aspectRatio(screenAspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Self.screenCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.screenCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                } else if let posterImage {
                    // Degraded fallback: scrcpy failed to start (bad/missing
                    // server, handshake failure) — a static poster still
                    // beats a blank pane. No live interaction in this mode.
                    Image(nsImage: posterImage)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Self.screenCornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Self.screenCornerRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                } else {
                    Spacer()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Connecting to the phone's screen…")
                            .font(.caption)
                            .foregroundStyle(Color.slateTextDim)
                    }
                    Spacer()
                }

                // Only while there's nothing live to show. A caption under a
                // running phone is a line of chrome charged to the screen's
                // height — and the streaming hint it carried ("click to type")
                // is answered by the phone itself the moment you click it.
                if !isStreaming {
                    Text("Beta · Click screen to type · Streams over adb")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.slateTextDim.opacity(0.7))
                        .padding(.top, 4)
                }
            }
            .padding(embeddedScreenBezel)

            if model.activeSerial != nil && (isStreaming || posterImage != nil) {
                // Flush to the top and full width: the expanded bar reaches the
                // window's edges so its corner mask clips it, and the idle notch
                // floats itself down from here. No inset, or the square bar would
                // strand a gap above the window's rounded corners.
                island
            }
        }
        .task(id: model.activeSerial) {
            await streamScreen()
        }
        .onChange(of: isStreaming) { streaming in
            streaming ? startKeyMonitor() : stopKeyMonitor()
        }
        .onChange(of: model.audioMuted) { muted in
            audioPlayer?.setMuted(muted)
        }
        .onDisappear(perform: stopKeyMonitor)
    }

    // MARK: - Keyboard

    /// Keys can only be caught with a local monitor here.
    ///
    /// The window is borderless, so AppKit refuses to make it key, and keyDown
    /// is only ever delivered to a key window's first responder — the view's own
    /// keyDown override never fired once. The events do reach the *process*
    /// (andross is the frontmost app when you're typing at it); they just have
    /// nowhere to be routed. A local monitor reads them off the app's event
    /// stream before that routing, and returning nil swallows them so the phone
    /// is the only thing that hears the keystroke.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let commandHeld = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.command)
            switch routeMacKey(virtualKey: event.keyCode,
                               characters: event.characters,
                               commandHeld: commandHeld,
                               clipboard: NSPasteboard.general.string(forType: .string)) {
            case .text(let text):
                sendText(text)
                return nil
            case .keycode(let code):
                sendKeycode(code)
                return nil
            case .ignore:
                return event   // Cmd+Q and friends still belong to macOS
            }
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The phone's notch: the shared `Island` with the phone's own keys on the
    /// right. Back (a mouse has no edge-swipe worth the name) and Exit; then
    /// pop-out. Home and Recents are deliberately absent — the shell *is* the
    /// launcher, so `streamScreen` leaves the screen the moment Android's
    /// launcher comes forward, which makes Home a long way round to the ✕, and
    /// Recents summons the multitasker the thin shell exists to hide. The phone's
    /// own home bar still swipes up to both.
    private var island: some View {
        Island {
            HStack(spacing: 8) {
                // The phone's ring/silent switch, rehoused on the island. Gain-
                // based, so it silences without cutting the stream.
                Button {
                    model.audioMuted.toggle()
                } label: {
                    Image(systemName: model.audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(model.audioMuted ? Color.slateRed : Color.white.opacity(0.85))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(model.audioMuted ? "Unmute Phone Audio" : "Mute Phone Audio")
                .accessibilityLabel(model.audioMuted ? "Unmute Phone Audio" : "Mute Phone Audio")

                navKey(icon: "chevron.backward", key: .back, label: "Back")

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.activeApp = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.slateRed)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain).help("Exit Screen").accessibilityLabel("Exit Screen")

                Button { model.toggleHeadedHeadless() } label: {
                    Image(systemName: model.headlessBoot ? "arrow.up.right.square" : "arrow.down.left.square")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(model.headlessBoot ? "Pop Out Phone Window" : "Embed Phone Window")
                .accessibilityLabel(model.headlessBoot ? "Pop Out Phone Window" : "Embed Phone Window")
            }
        }
    }

    private func navKey(icon: String, key: EmulatorManager.AndroidKey, label: String) -> some View {
        Button {
            guard let serial = model.activeSerial else { return }
            Task.detached(priority: .userInitiated) {
                _ = EmulatorManager.shared.inputKey(serial: serial, key: key)
            }
        } label: {
            // No disc behind the glyph: inside the island's own black pill a
            // second background would just be a smudge on it.
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Input (live, over the scrcpy control socket)

    private func sendTouch(_ action: ScrcpyControl.TouchAction, at viewPoint: CGPoint, in viewSize: CGSize) {
        guard let client, devicePixels.width > 0, devicePixels.height > 0 else { return }
        let fitted = fittedDeviceRect(devicePixels: devicePixels, container: viewSize)
        guard let device = devicePoint(viewPoint, fitted: fitted, devicePixels: devicePixels) else { return }
        let width = UInt16(clamping: Int(devicePixels.width))
        let height = UInt16(clamping: Int(devicePixels.height))
        Task.detached(priority: .userInitiated) {
            _ = client.sendTouch(action: action, x: Int32(device.x), y: Int32(device.y),
                                 screenWidth: width, screenHeight: height)
        }
    }

    /// Wheel/trackpad scroll → a finger dragging on the phone.
    ///
    /// Not INJECT_SCROLL, which is what this obviously should be and measurably
    /// isn't: injected as a mouse wheel, scrolling *up* moves the list and
    /// scrolling *down* does nothing at all — verified on Settings with the
    /// wire bytes dumped and confirmed symmetric, so the events leave correct
    /// and the device drops half of them. A phone is scrolled with a finger,
    /// and finger injection is the path this app already proves works.
    ///
    /// So a scroll becomes a real gesture: touch down on the first event, move
    /// with each one after, lift once the scrolling stops. Android reads the
    /// velocity of those moves the way it reads a thumb's, which is where the
    /// fling comes from for free — and it works in apps that ignore a wheel
    /// entirely, which on a phone is most of them.
    private func sendScroll(at viewPoint: CGPoint, in viewSize: CGSize, deltaX: CGFloat, deltaY: CGFloat) {
        guard devicePixels.width > 0, devicePixels.height > 0 else { return }
        let fitted = fittedDeviceRect(devicePixels: devicePixels, container: viewSize)
        guard fitted.contains(viewPoint) else { return }

        // The gesture lives in view coordinates and is converted on the way out,
        // so the same touch mapping the mouse uses applies here too.
        if scrollFinger == nil {
            scrollFinger = viewPoint
            sendTouch(.down, at: viewPoint, in: viewSize)
        }
        // macOS reports scroll deltas the direction the *content* should move,
        // which is the direction the finger goes. Pass them straight through.
        let moved = CGPoint(x: (scrollFinger?.x ?? viewPoint.x) + deltaX,
                            y: (scrollFinger?.y ?? viewPoint.y) + deltaY)
        // Keep the finger on the glass: a scroll that runs past the edge would
        // otherwise map outside the screen and be dropped mid-gesture.
        let clamped = CGPoint(x: min(max(moved.x, fitted.minX + 1), fitted.maxX - 1),
                              y: min(max(moved.y, fitted.minY + 1), fitted.maxY - 1))
        scrollFinger = clamped
        sendTouch(.move, at: clamped, in: viewSize)

        // Lift the finger once the wheel goes quiet. Each event pushes the
        // deadline out, so one continuous flick stays one continuous gesture.
        scrollLift?.cancel()
        let lift = DispatchWorkItem {
            guard let finger = scrollFinger else { return }
            sendTouch(.up, at: finger, in: viewSize)
            scrollFinger = nil
        }
        scrollLift = lift
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: lift)
    }

    private func sendText(_ text: String) {
        guard let client else { return }
        Task.detached(priority: .userInitiated) {
            _ = client.sendText(text)
        }
    }

    private func sendKeycode(_ keycode: Int) {
        guard let client else { return }
        Task.detached(priority: .userInitiated) {
            _ = client.sendKeycode(action: .down, keycode: Int32(keycode))
            _ = client.sendKeycode(action: .up, keycode: Int32(keycode))
        }
    }

    // MARK: - Streaming lifecycle

    /// Every few seconds it checks the foreground app: the moment Android
    /// lands on its own launcher, the thin shell takes over again (the
    /// Android desktop is never shown). Time-driven, not frame-count-driven
    /// — real streaming can run at 30-60fps, unlike the old ~2fps poll.
    private func streamScreen() async {
        guard let serial = model.activeSerial else { return }
        isStreaming = false
        posterImage = nil
        // A new session may be a different device with a different shape — never
        // let the last one's aspect size this one's window.
        model.streamAspect = nil
        devicePixels = .zero
        displayView.reset()

        let launcher = await Task.detached(priority: .userInitiated) {
            EmulatorManager.shared.defaultLauncherPackage(serial: serial)
        }.value

        let newClient = ScrcpyClient(serial: serial)
        client = newClient

        guard let stream = await newClient.start() else {
            // Degrade to a static poster rather than a blank pane.
            // captureScreen returns raw `screencap` output (12-byte header
            // + RGBA pixels), not an encoded image — build the CGImage by
            // hand, same as the old raw-frame poll used to.
            let raw = await Task.detached(priority: .userInitiated) {
                EmulatorManager.shared.captureScreen(serial: serial)
            }.value
            if let raw, let header = AndrossParse.screencapHeader(from: [UInt8](raw.prefix(12))) {
                let pixelData = raw.dropFirst(12)
                if pixelData.count >= header.pixelByteCount,
                   let provider = CGDataProvider(data: pixelData as CFData),
                   let cgImage = CGImage(
                       width: header.width, height: header.height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: header.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                   ) {
                    posterImage = NSImage(cgImage: cgImage, size: NSSize(width: header.width, height: header.height))
                }
            }
            return
        }

        isStreaming = true

        // Audio rides its own socket alongside video. A device that can't
        // capture — an emulator once booted `-no-audio`, Android < 11 — answers
        // `.unavailable` and the engine never starts, so the screen is
        // untouched by audio's absence. The reading task owns the whole engine
        // lifecycle (start on first packet, stop when the socket closes), so
        // teardown is just closing the client: that ends the stream, and the
        // task stops the player itself.
        let audioTask: Task<Void, Never>?
        if let player = AudioPlayer() {
            player.setMuted(model.audioMuted)
            audioPlayer = player
            audioTask = Task.detached(priority: .userInitiated) {
                guard let audioStream = newClient.makeAudioStream() else { return }
                var engineUp = false
                loop: for await audio in audioStream {
                    switch audio {
                    case .unavailable:
                        break loop
                    case .pcm(let pcm):
                        if !engineUp { engineUp = true; player.start() }
                        player.enqueue(pcm)
                    }
                }
                player.stop()
            }
        } else {
            audioTask = nil
        }

        defer {
            audioTask?.cancel()
            audioPlayer = nil
            newClient.stop()
        }

        let foregroundCheckInterval: TimeInterval = 2
        var lastForegroundCheck = Date()

        for await event in stream {
            if Task.isCancelled { break }
            switch event {
            case .sessionMeta(let width, let height):
                devicePixels = CGSize(width: width, height: height)
                // Hand the phone's shape to the window, which resizes to match.
                // A device that rotates mid-stream re-announces itself here, so
                // the window turns with it.
                if height > 0 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        model.streamAspect = CGFloat(width) / CGFloat(height)
                    }
                }
            case .frame(let frame):
                if frame.isConfig {
                    displayView.handle(configPacket: frame.data)
                } else {
                    displayView.enqueue(frame: frame.data, isKeyFrame: frame.isKeyFrame)
                }
            }

            guard let launcher, Date().timeIntervalSince(lastForegroundCheck) >= foregroundCheckInterval else { continue }
            lastForegroundCheck = Date()
            let foreground = await Task.detached(priority: .userInitiated) {
                EmulatorManager.shared.foregroundPackage(serial: serial)
            }.value
            if !Task.isCancelled, foreground == launcher {
                isStreaming = false
                withAnimation(.easeOut(duration: 0.15)) {
                    model.activeApp = nil
                }
                return
            }
        }
        isStreaming = false
    }
}
