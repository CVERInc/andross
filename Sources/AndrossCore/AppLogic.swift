import CoreGraphics

// MARK: - Pure UI-adjacent logic
//
// Decision logic lifted out of the SwiftUI view model so it can be unit
// tested without a running app or a booted device. Everything here is a
// pure value type or a pure function of its inputs.

/// Append-only activity log with transient-line coalescing.
///
/// A "transient" line (e.g. a `\r` progress update) overwrites the previous
/// transient line instead of stacking; the next permanent line replaces the
/// last transient one. Capped to `limit` entries to bound memory.
public struct LogBuffer: Sendable {
    public private(set) var lines: [String] = []
    private var lastIsTransient = false
    private let limit: Int

    public init(limit: Int = 100) {
        self.limit = limit
    }

    public mutating func append(_ message: String, transient: Bool = false) {
        if lastIsTransient, !lines.isEmpty {
            lines[lines.count - 1] = message
        } else {
            lines.append(message)
        }
        lastIsTransient = transient
        if lines.count > limit {
            lines.removeFirst()
        }
    }

    public mutating func clear() {
        lines.removeAll()
        lastIsTransient = false
    }
}

/// Resolve which AVD an action should target.
///
/// When a phone is running and we know which AVD it booted from, prefer that;
/// otherwise fall back to the user's selection, then the first known AVD.
public func resolveTargetDevice(isRunning: Bool,
                                activeDeviceName: String,
                                selectedAVD: String?,
                                avds: [String]) -> String? {
    if isRunning, !activeDeviceName.isEmpty { return activeDeviceName }
    return selectedAVD ?? avds.first
}

/// Window size (points) for the phone shell given device class & orientation.
public func phoneWindowSize(isTablet: Bool, isLandscape: Bool) -> CGSize {
    let long: CGFloat = 800
    let shortSide: CGFloat = isTablet ? 500 : 360
    return isLandscape
        ? CGSize(width: long, height: shortSide)
        : CGSize(width: shortSide, height: long)
}

/// What a Mac key press should become on the phone.
public enum KeyRoute: Equatable {
    case keycode(Int)   // an Android KEYCODE_* (arrows, delete, enter, back…)
    case text(String)   // characters to type — UTF-8, so CJK needs no escaping
    case ignore
}

/// Route one Mac key event to the phone.
///
/// Pure, so the mapping is testable without an NSEvent: the caller passes the
/// virtual key, the characters AppKit resolved (already reflecting the user's
/// own layout and dead keys), whether Command was held, and the clipboard.
///
/// Cmd+V becomes text rather than a KEYCODE_PASTE, so it pastes what is on the
/// *Mac's* clipboard — the phone's own clipboard is a different thing, and the
/// one you just copied from is this one.
public func routeMacKey(virtualKey: UInt16,
                        characters: String?,
                        commandHeld: Bool,
                        clipboard: String?) -> KeyRoute {
    if commandHeld {
        guard virtualKey == 9 else { return .ignore }   // 9 = V
        guard let clipboard, !clipboard.isEmpty else { return .ignore }
        return .text(clipboard)
    }

    switch virtualKey {
    case 123: return .keycode(21)   // DPAD_LEFT
    case 124: return .keycode(22)   // DPAD_RIGHT
    case 126: return .keycode(19)   // DPAD_UP
    case 125: return .keycode(20)   // DPAD_DOWN
    case 51:  return .keycode(67)   // DEL (Backspace)
    case 36:  return .keycode(66)   // ENTER
    case 48:  return .keycode(61)   // TAB
    case 53:  return .keycode(4)    // BACK (Escape)
    default:  break
    }

    guard let characters, !characters.isEmpty else { return .ignore }
    // Drop control characters: they have no business being typed, and the ones
    // that do (tab, newline) already went out as keycodes above.
    let typable = characters.filter { character in
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F
    }
    return typable.isEmpty ? .ignore : .text(typable)
}

/// Bezel (points) between the window edge and the embedded screen — the only
/// part of the window left draggable once the phone fills it, so it can't go
/// to zero: the window is borderless and the screen's own interaction view
/// refuses to move it.
public let embeddedScreenBezel: CGFloat = 10

/// The window and screen sizes for the embedded screen, derived from the
/// stream's own aspect ratio.
///
/// The shell used to keep a fixed window and aspect-fit the video inside it;
/// header/caption chrome ate height but not width, so the pane stopped being
/// phone-shaped and the video pillar-boxed inside its own border (measured:
/// a 340x665 pane showing a 0.45 device wasted 40.75pt of width). Sizing the
/// window from the device instead means the screen fills it exactly on any
/// device — the shell takes the phone's shape rather than the phone rattling
/// around in the shell's.
///
/// `longSide` is the caller's size preset (the long edge of the window); the
/// short edge follows from `deviceAspect` (width / height of the stream).
/// Orientation follows the device, not the preset: a portrait stream yields a
/// portrait window even if the preset was landscape.
///
/// Nothing is reserved for the island. It sits on the dead centre of Android's
/// status bar — clock left, icons right, nothing between — so the controls cost
/// the screen no height at all, the way the hardware island costs an iPhone
/// none. An emulator has no camera to make room for; the notch is ours.
public func embeddedScreenWindowSize(deviceAspect: CGFloat,
                                     longSide: CGFloat,
                                     bezel: CGFloat = embeddedScreenBezel) -> (window: CGSize, screen: CGSize) {
    guard deviceAspect > 0, longSide > 2 * bezel else { return (.zero, .zero) }
    let screenLong = longSide - 2 * bezel
    let screen = deviceAspect <= 1
        ? CGSize(width: screenLong * deviceAspect, height: screenLong)   // portrait: height is the long edge
        : CGSize(width: screenLong, height: screenLong / deviceAspect)   // landscape: width is
    let window = CGSize(width: screen.width + 2 * bezel, height: screen.height + 2 * bezel)
    return (window, screen)
}

/// Aspect-fit rect of a device screen (`devicePixels`) centred inside an
/// available container, matching SwiftUI's `.aspectRatio(.fit)` layout. Returns
/// `.zero` for any non-positive input so callers can reject the mapping.
public func fittedDeviceRect(devicePixels: CGSize, container: CGSize) -> CGRect {
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

/// Map a point in container/view coordinates to device pixel coordinates.
///
/// Returns nil when the point falls in the letterbox/pillar-box margin outside
/// the fitted screen — a tap there must not be sent as a (clamped) edge tap.
/// `fitted` is the rect from `fittedDeviceRect`.
public func devicePoint(_ p: CGPoint, fitted: CGRect, devicePixels: CGSize) -> CGPoint? {
    guard fitted.width > 0, fitted.height > 0 else { return nil }
    let relX = (p.x - fitted.minX) / fitted.width
    let relY = (p.y - fitted.minY) / fitted.height
    guard (0...1).contains(relX), (0...1).contains(relY) else { return nil }
    return CGPoint(x: relX * devicePixels.width, y: relY * devicePixels.height)
}

/// Clamp a remembered window frame back onto the currently visible screen.
///
/// A position persisted on one display layout can land fully or partly
/// off-screen after a restart (monitor unplugged, resolution change, dock/menu
/// bar shift). Restoring it verbatim leaves the window unreachable. This keeps
/// the size but slides the origin so the whole frame sits inside `visibleFrame`
/// (shrinking only if the window is larger than the screen). Origin is in the
/// macOS bottom-left coordinate space, matching `NSScreen.visibleFrame`.
public func clampedWindowFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
    guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
    let width = min(frame.width, visibleFrame.width)
    let height = min(frame.height, visibleFrame.height)
    let minX = visibleFrame.minX
    let maxX = visibleFrame.maxX - width
    let minY = visibleFrame.minY
    let maxY = visibleFrame.maxY - height
    let x = min(max(frame.origin.x, minX), maxX)
    let y = min(max(frame.origin.y, minY), maxY)
    return CGRect(x: x, y: y, width: width, height: height)
}
