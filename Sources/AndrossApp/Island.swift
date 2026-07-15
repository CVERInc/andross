import SwiftUI
import AppKit
import AndrossCore
import Signet

/// A transparent AppKit view that lets a drag begun on it move the window.
///
/// The window is borderless and `isMovableByWindowBackground`, so bare
/// background moves it — but a SwiftUI shape fill counts as content and swallows
/// the drag, which is why only the bezel moved the window before. Behind the
/// controls, with the fill marked non-hit-testing above it, this turns the pill
/// into a grab handle: the buttons sit on top and still click, the empty space
/// drags the whole window, the way the notch does on a phone.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// The notch — one black element, worn by both the home screen and the phone
/// screen, so the two read as the same app.
///
/// This is the single source for it; each screen renders an `Island` and only
/// supplies the `trailing` controls that differ. (They were two hand-copied
/// pills once, which is exactly how the traffic lights drifted out of sync.)
///
/// At rest it's a bare centered notch, standing in for the old "andross"
/// wordmark and echoing the hardware Dynamic Island. Reaching for it turns the
/// whole top edge into a black status bar: the window's own lights land at the
/// top-left, where macOS keeps them, and the caller's controls at the top-right,
/// its upper corners following the screen's own rounding so it reads as the top
/// of the phone going dark rather than a bar laid over it. Nothing shows at
/// rest, so nothing jumps when the controls arrive. Dragging any empty part
/// moves the window — the notch is the natural grab handle.
struct Island<Trailing: View>: View {
    @ObservedObject var model = AppModel.shared
    /// Home wears the bar the whole time; only the phone screen hides into a
    /// notch, because only the phone screen has content to keep clear of the
    /// status-bar corners. When always-open the wordmark is simply always home.
    var alwaysExpanded: Bool = false
    /// Context controls for the top-right — the phone's keys on the screen, the
    /// screen/pop-out toggles on the home screen, nothing when idle at home.
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovering = false

    private let idleWidth: CGFloat = 90
    private let idleHeight: CGFloat = 26

    private var expanded: Bool { alwaysExpanded || hovering }

    var body: some View {
        ZStack(alignment: .top) {
            if expanded {
                expandedBar
            } else {
                idleNotch
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onHover { inside in
            guard !alwaysExpanded else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                hovering = inside
            }
        }
    }

    /// The resting notch: a small black capsule floating just below the top
    /// edge, Dynamic-Island style. This owns its whole vertical offset — the
    /// host places the island flush so the expanded bar can reach the top, and
    /// the notch pads itself down from there.
    private var idleNotch: some View {
        Color.clear
            .frame(width: idleWidth, height: idleHeight)
            .background(WindowDragArea())
            .background(Capsule().fill(Color.black).allowsHitTesting(false))
            .padding(.top, 15)
    }

    /// The expanded status bar: full width, flush to the top, square corners.
    /// It doesn't round itself — the window's own 55pt corner mask clips it, the
    /// same mask that rounds the streamed screen's bottom, so the bar's top
    /// corners match the window exactly with nothing to keep in sync by hand.
    private var expandedBar: some View {
        HStack(spacing: 0) {
            lights
            Spacer(minLength: 24)
            trailing()
        }
        // The wordmark rides the true center, unmoved by whatever controls sit
        // on the right — it's back where the phone puts the carrier name, the
        // spot it lost when the header lost its title bar.
        .overlay(
            Text("andross")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .kerning(0.5)
                .foregroundColor(.white.opacity(0.9))
                .allowsHitTesting(false)
        )
        // Generous top and side padding so the row clears the window's rounded
        // corners — the lights shouldn't crowd the arc where the top edge turns
        // down, and the bar reads as a proper status bar, not a thin strip.
        .padding(.top, 17)
        .padding(.bottom, 12)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        // Fill is non-hit-testing so a mouse-down on the empty bar falls through
        // to the drag area behind it; a filled SwiftUI shape otherwise swallows
        // the event before AppKit's move-by-background sees it.
        .background(WindowDragArea())
        .background(Rectangle().fill(Color.black).allowsHitTesting(false))
        .transition(.opacity)
    }

    /// Window lights — hand-drawn because real standardWindowButton widgets
    /// render as dead black dots outside their titlebar slot (see
    /// configureWindow), and each must reach *this* window, never NSApp.keyWindow
    /// (nil for a borderless window — the old yellow-light bug).
    private var lights: some View {
        HStack(spacing: 9) {
            Button { NSApp.terminate(nil) } label: {
                Circle().fill(Color.slateRed).frame(width: 12, height: 12)
            }
            .buttonStyle(.plain).help("Close (quits andross)").accessibilityLabel("Close")

            Button { model.mainWindow?.miniaturize(nil) } label: {
                Circle().fill(Color(hex: 0xFFBD2E)).frame(width: 12, height: 12)
            }
            .buttonStyle(.plain).help("Minimize").accessibilityLabel("Minimize")

            // Green keeps a click, not a hover: it toggles the size / rotation
            // popover (the light andross keeps where iPhone Mirroring drops it),
            // and a real .popover off a plain button lands where SwiftUI's Menu
            // collapses to a point.
            Button { model.sizeMenuVisible.toggle() } label: {
                Circle().fill(Color.androidGreen).frame(width: 12, height: 12)
            }
            .buttonStyle(.plain).help("Window size & rotation").accessibilityLabel("Window size")
            .popover(isPresented: $model.sizeMenuVisible, arrowEdge: .bottom) {
                SizeMenu(model: model)
            }
        }
    }
}
