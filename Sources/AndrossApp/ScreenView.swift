import SwiftUI
import AppKit
import AndrossCore
import Signet

/// AppKit interaction layer for the embedded screen. A plain SwiftUI gesture
/// can't be used here: the window is movable-by-background, and a mouse-down
/// on a non-control view starts a window drag instead of the gesture. This
/// NSView opts out of window dragging and reports tap/drag endpoints in
/// top-left coordinates. It also intercepts key down events and forwards
/// them to the running virtual device.
private struct ScreenInteraction: NSViewRepresentable {
    let onGesture: (_ start: CGPoint, _ end: CGPoint, _ viewSize: CGSize) -> Void
    let onText: (_ text: String) -> Void
    let onKey: (_ keycode: Int) -> Void

    final class InteractionView: NSView {
        var onGesture: ((CGPoint, CGPoint, CGSize) -> Void)?
        var onText: ((String) -> Void)?
        var onKey: ((Int) -> Void)?
        private var downPoint: CGPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        // The borderless window never becomes key, so every click arrives
        // as a "first mouse" — accept it or we'd never see any events.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            downPoint = convert(event.locationInWindow, from: nil)
        }

        override func mouseUp(with event: NSEvent) {
            guard let start = downPoint else { return }
            downPoint = nil
            let end = convert(event.locationInWindow, from: nil)
            onGesture?(start, end, bounds.size)
        }

        override func keyDown(with event: NSEvent) {
            // Check for Command+V (Paste shortcut)
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifierFlags == .command {
                if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "v" {
                    if let clipboardText = NSPasteboard.general.string(forType: .string), !clipboardText.isEmpty {
                        onText?(clipboardText)
                    }
                    return
                }
            }

            guard let characters = event.characters, !characters.isEmpty else {
                super.keyDown(with: event)
                return
            }

            // Check for special keycodes
            let keyCode = event.keyCode
            var androidKey: Int? = nil
            switch keyCode {
            case 123: androidKey = 21 // DPAD_LEFT
            case 124: androidKey = 22 // DPAD_RIGHT
            case 126: androidKey = 19 // DPAD_UP
            case 125: androidKey = 20 // DPAD_DOWN
            case 51:  androidKey = 67 // DEL (Backspace)
            case 36:  androidKey = 66 // ENTER
            case 48:  androidKey = 61 // TAB
            case 53:  androidKey = 4  // BACK (Escape)
            default: break
            }

            if let androidKey {
                onKey?(androidKey)
            } else {
                // Filter out control characters that should not be typed directly
                let filtered = characters.filter { char in
                    let scalar = char.unicodeScalars.first?.value ?? 0
                    return scalar >= 0x20 || scalar == 9 || scalar == 10 || scalar == 13
                }
                if !filtered.isEmpty {
                    onText?(String(filtered))
                }
            }
        }
    }

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onGesture = onGesture
        view.onText = onText
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.onGesture = onGesture
        view.onText = onText
        view.onKey = onKey
    }
}

/// The phone's screen, embedded in the andross window (beta).
///
/// Frames arrive by polling `screencap` over adb — a few fps, enough for
/// messengers and setup flows. Clicks and drags are mapped back to device
/// coordinates and injected as taps/swipes. Keyboards forward events.
struct ScreenAppView: View {
    @ObservedObject var model: AppModel

    @State private var frame: NSImage? = nil
    @State private var devicePixels: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
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
                } else if let frame {
                    GeometryReader { geo in
                        Image(nsImage: frame)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .overlay(
                                ScreenInteraction(
                                    onGesture: { start, end, viewSize in
                                        sendGesture(from: start, to: end, in: viewSize)
                                    },
                                    onText: { text in
                                        sendText(text)
                                    },
                                    onKey: { keycode in
                                        sendKeycode(keycode)
                                    }
                                )
                            )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
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

                Text("Beta · Click screen to type · Streams over adb")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.slateTextDim.opacity(0.7))
                    .padding(.top, 4)
            }
            .padding(10)

            // Floating escape hatch (top-right controls)
            if model.activeSerial != nil && frame != nil {
                HStack(spacing: 6) {
                    navKey(icon: "chevron.backward", key: .back, label: "Back")
                    navKey(icon: "house", key: .home, label: "Home")
                    navKey(icon: "square.on.square", key: .appSwitch, label: "Recents")
                    
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            model.activeApp = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.slateRed)
                            .frame(width: 20, height: 20)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Exit Screen")
                    .accessibilityLabel("Exit Screen")
                }
                .padding(4)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .padding(14)
            }
        }
        .task(id: model.activeSerial) {
            await streamFrames()
        }
    }

    private func navKey(icon: String, key: EmulatorManager.AndroidKey, label: String) -> some View {
        Button {
            guard let serial = model.activeSerial else { return }
            Task.detached(priority: .userInitiated) {
                _ = EmulatorManager.shared.inputKey(serial: serial, key: key)
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func sendGesture(from startView: CGPoint, to endView: CGPoint, in viewSize: CGSize) {
        // Coordinate mapping lives in AndrossCore (unit-tested) so the view and
        // the tests share one implementation and can't drift.
        let fitted = fittedDeviceRect(devicePixels: devicePixels, container: viewSize)
        guard let serial = model.activeSerial,
              let start = devicePoint(startView, fitted: fitted, devicePixels: devicePixels) else { return }
        let end = devicePoint(endView, fitted: fitted, devicePixels: devicePixels) ?? start

        let dx = end.x - start.x, dy = end.y - start.y
        let isTap = (dx * dx + dy * dy).squareRoot() < 10

        Task.detached(priority: .userInitiated) {
            if isTap {
                _ = EmulatorManager.shared.inputTap(serial: serial, x: Int(start.x), y: Int(start.y))
            } else {
                _ = EmulatorManager.shared.inputSwipe(serial: serial,
                                                      fromX: Int(start.x), fromY: Int(start.y),
                                                      toX: Int(end.x), toY: Int(end.y))
            }
        }
    }

    private func sendText(_ text: String) {
        guard let serial = model.activeSerial else { return }
        Task.detached(priority: .userInitiated) {
            _ = EmulatorManager.shared.inputText(serial: serial, text)
        }
    }

    private func sendKeycode(_ keycode: Int) {
        guard let serial = model.activeSerial else { return }
        Task.detached(priority: .userInitiated) {
            _ = EmulatorManager.shared.inputKeyevent(serial: serial, keycode: keycode)
        }
    }

    /// Sequential frame loop — the next capture starts only after the last
    /// one finished, so adb is never flooded. Every few frames it checks the
    /// foreground app: the moment Android lands on its own launcher, the
    /// thin shell takes over again (the Android desktop is never shown).
    private func streamFrames() async {
        guard let serial = model.activeSerial else { return }

        let launcher = await Task.detached(priority: .userInitiated) {
            EmulatorManager.shared.defaultLauncherPackage(serial: serial)
        }.value

        let stream = EmulatorManager.shared.streamScreen(serial: serial)
        var frameCount = 0

        for await frameData in stream {
            if Task.isCancelled { break }

            let width = frameData.width
            let height = frameData.height
            let pixelData = frameData.pixelData

            if let provider = CGDataProvider(data: pixelData as CFData),
               let cgImage = CGImage(
                   width: width,
                   height: height,
                   bitsPerComponent: 8,
                   bitsPerPixel: 32,
                   bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider,
                   decode: nil,
                   shouldInterpolate: true,
                   intent: .defaultIntent
               ) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
                devicePixels = CGSize(width: width, height: height)
                frame = nsImage
            }

            frameCount += 1
            // Don't check during the first few seconds — an app we just
            // launched may still be cold-starting behind the launcher.
            if let launcher, frameCount >= 9, frameCount % 5 == 0 {
                let foreground = await Task.detached(priority: .userInitiated) {
                    EmulatorManager.shared.foregroundPackage(serial: serial)
                }.value
                if !Task.isCancelled, foreground == launcher {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.activeApp = nil
                    }
                    return
                }
            }
        }
    }
}
