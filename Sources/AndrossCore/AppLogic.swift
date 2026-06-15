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
