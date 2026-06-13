import SwiftUI
import AppKit
import AndrossCore

/// AppKit interaction layer for the embedded screen. A plain SwiftUI gesture
/// can't be used here: the window is movable-by-background, and a mouse-down
/// on a non-control view starts a window drag instead of the gesture. This
/// NSView opts out of window dragging and reports tap/drag endpoints in
/// top-left coordinates.
private struct ScreenInteraction: NSViewRepresentable {
    let onGesture: (_ start: CGPoint, _ end: CGPoint, _ viewSize: CGSize) -> Void

    final class InteractionView: NSView {
        var onGesture: ((CGPoint, CGPoint, CGSize) -> Void)?
        private var downPoint: CGPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        override var isFlipped: Bool { true }

        // The borderless window never becomes key, so every click arrives
        // as a "first mouse" — accept it or we'd never see any events.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            downPoint = convert(event.locationInWindow, from: nil)
        }

        override func mouseUp(with event: NSEvent) {
            guard let start = downPoint else { return }
            downPoint = nil
            let end = convert(event.locationInWindow, from: nil)
            onGesture?(start, end, bounds.size)
        }
    }

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onGesture = onGesture
        return view
    }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.onGesture = onGesture
    }
}

/// The phone's screen, embedded in the andross window (beta).
///
/// Frames arrive by polling `screencap` over adb — a few fps, enough for
/// messengers and setup flows. Clicks and drags are mapped back to device
/// coordinates and injected as taps/swipes.
struct ScreenAppView: View {
    @ObservedObject var model: AppModel

    @State private var frame: NSImage? = nil
    @State private var devicePixels: CGSize = .zero

    var body: some View {
        VStack(spacing: 8) {
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
                            ScreenInteraction { start, end, viewSize in
                                sendGesture(from: start, to: end, in: viewSize)
                            }
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

            // Thin-shell navigation: only Back. Android's own home and
            // recents have no meaning here — leaving the app returns to
            // the native home automatically.
            navKey(icon: "chevron.backward", key: .back, label: "Back")
                .padding(.vertical, 4)

            Text("Beta · streams a few frames per second over adb")
                .font(.system(size: 8))
                .foregroundStyle(Color.slateTextDim.opacity(0.7))
        }
        .padding(10)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 40, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Aspect-fit rect of the device frame inside the available space.
    private func fittedRect(in container: CGSize) -> CGRect {
        guard devicePixels.width > 0, devicePixels.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / devicePixels.width,
                        container.height / devicePixels.height)
        let size = CGSize(width: devicePixels.width * scale,
                          height: devicePixels.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func devicePoint(_ p: CGPoint, fitted: CGRect) -> CGPoint? {
        guard fitted.width > 0 else { return nil }
        let relX = (p.x - fitted.minX) / fitted.width
        let relY = (p.y - fitted.minY) / fitted.height
        guard (0...1).contains(relX), (0...1).contains(relY) else { return nil }
        return CGPoint(x: relX * devicePixels.width, y: relY * devicePixels.height)
    }

    private func sendGesture(from startView: CGPoint, to endView: CGPoint, in viewSize: CGSize) {
        let fitted = fittedRect(in: viewSize)
        guard let serial = model.activeSerial,
              let start = devicePoint(startView, fitted: fitted) else { return }
        let end = devicePoint(endView, fitted: fitted) ?? start

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

    /// Sequential frame loop — the next capture starts only after the last
    /// one finished, so adb is never flooded. Every few frames it checks the
    /// foreground app: the moment Android lands on its own launcher, the
    /// thin shell takes over again (the Android desktop is never shown).
    private func streamFrames() async {
        guard let serial = model.activeSerial else { return }

        let launcher = await Task.detached(priority: .userInitiated) {
            EmulatorManager.shared.defaultLauncherPackage(serial: serial)
        }.value

        var frameCount = 0
        while !Task.isCancelled {
            let data = await Task.detached(priority: .userInitiated) {
                EmulatorManager.shared.captureScreen(serial: serial)
            }.value

            if !Task.isCancelled, let data, let image = NSImage(data: data) {
                if let rep = NSBitmapImageRep(data: data) {
                    devicePixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                }
                frame = image
            }

            frameCount += 1
            // Don't check during the first few seconds — an app we just
            // launched may still be cold-starting behind the launcher.
            if let launcher, frameCount >= 9, frameCount % 3 == 0 {
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

            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }
}
