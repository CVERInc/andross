import SwiftUI
import AppKit
import AndrossCore
import Signet

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
    @State private var dragOrigin: CGPoint?
    @State private var dragMouseStart: CGPoint?

    private let idleWidth: CGFloat = 90
    private let idleHeight: CGFloat = 26

    private var expanded: Bool { alwaysExpanded || hovering }

    var body: some View {
        ZStack(alignment: .top) {
            if expanded {
                // While open the whole bar holds it open, and leaving it (down
                // into the screen) closes it. The bar covers the phone's status
                // bar, which is fine because it's now here on purpose.
                expandedBar
                    .onHover { inside in
                        guard !alwaysExpanded else { return }
                        setHovering(inside)
                    }
            } else {
                // Only the notch opens the bar — never the full width. Hovering
                // the sides, where the phone draws its own clock and battery,
                // must leave those reachable rather than summon a bar on top of
                // the very thing you reached for. Opening only; the expanded bar
                // owns closing, so the notch→bar hand-off can't flicker.
                idleNotch
                    .onHover { inside in
                        if inside { setHovering(true) }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func setHovering(_ value: Bool) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            hovering = value
        }
    }

    /// Drag the whole window by the island. A real AppKit drag area
    /// (`mouseDownCanMoveWindow`) never moved the window from here — on the
    /// phone screen the touch layer sits above and eats the mouse-down before
    /// AppKit's move-by-background can act. A SwiftUI gesture rides the same
    /// event path as the buttons, which do work, so it reaches the island
    /// wherever the buttons do; it just repositions the window itself.
    private var windowDrag: some Gesture {
        // The gesture only detects the drag; the offset is measured from the
        // real cursor via `NSEvent.mouseLocation`, not the gesture translation.
        // SwiftUI's `.global` space is window-relative, so moving the window
        // shifts it under the gesture and the two cancel out — the window barely
        // creeps. Screen coordinates don't move with the window, so it tracks
        // the cursor exactly. Both are y-up here, so the delta adds directly.
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                guard let win = model.mainWindow else { return }
                let mouse = NSEvent.mouseLocation
                if dragOrigin == nil { dragOrigin = win.frame.origin; dragMouseStart = mouse }
                guard let origin = dragOrigin, let start = dragMouseStart else { return }
                win.setFrameOrigin(CGPoint(x: origin.x + (mouse.x - start.x),
                                           y: origin.y + (mouse.y - start.y)))
            }
            .onEnded { _ in dragOrigin = nil; dragMouseStart = nil }
    }

    /// The resting notch: a small black capsule floating just below the top
    /// edge, Dynamic-Island style. This owns its whole vertical offset — the
    /// host places the island flush so the expanded bar can reach the top, and
    /// the notch pads itself down from there.
    private var idleNotch: some View {
        Capsule().fill(Color.black)
            .frame(width: idleWidth, height: idleHeight)
            .contentShape(Capsule())
            .gesture(windowDrag)
            // Sits vertically centred on the phone's own status-bar row — the
            // notch reads as part of that row, level with the clock and the
            // battery, not floating above them.
            .padding(.top, 18)
    }

    /// The expanded status bar: full width, flush to the top, square corners.
    /// It doesn't round itself — the window's own 55pt corner mask clips it, the
    /// same mask that rounds the streamed screen's bottom, so the bar's top
    /// corners match the window exactly with nothing to keep in sync by hand.
    private var expandedBar: some View {
        // Bottom to top: a black fill that carries the window drag, then the
        // controls. A press on a button lands on the button; a press anywhere
        // else — the wordmark, the gaps — falls through to the fill and moves
        // the window. The wordmark opts out of hit-testing so it can't shadow
        // the drag.
        ZStack {
            Rectangle().fill(Color.black)
                .contentShape(Rectangle())
                .gesture(windowDrag)
            HStack(spacing: 0) {
                lights
                Spacer(minLength: 24)
                trailing()
            }
            // The wordmark rides the true center, unmoved by whatever controls
            // sit on the right — back where the phone puts the carrier name, the
            // spot it lost when the header lost its title bar.
            .overlay(
                Text("andross")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .kerning(0.5)
                    .foregroundColor(.white.opacity(0.9))
                    .allowsHitTesting(false)
            )
            // Generous top and side padding so the row clears the window's
            // rounded corners — the lights shouldn't crowd the arc where the top
            // edge turns down, and it reads as a proper status bar, not a strip.
            .padding(.top, 17)
            .padding(.bottom, 12)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
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
