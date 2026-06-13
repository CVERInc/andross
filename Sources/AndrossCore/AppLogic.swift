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
