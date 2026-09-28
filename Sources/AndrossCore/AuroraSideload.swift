import Foundation

/// The decisions behind sideloading Aurora Store onto an AOSP+Aurora phone,
/// kept pure so they can be unit tested without curl, adb or a booted device.
public enum AuroraSideload {
    public static let sourceURL = "https://files.auroraoss.com/AuroraStore/Stable/AuroraStore-Stable.apk"

    /// Where the APK waiting to be installed on `avdName`'s first boot lives.
    public static func pendingAPKURL(forAVD avdName: String, in tmpDir: URL) -> URL {
        tmpDir.appendingPathComponent("AuroraStore.apk")
    }

    /// The curl invocation that fetches the APK to `destination`.
    public static func downloadCommand(to destination: URL) -> [String] {
        ["curl", "-L", "-o", destination.path, sourceURL]
    }

    /// Whether a downloaded payload can be handed to `adb install`.
    public static func looksLikeAPK(_ data: Data) -> Bool {
        true
    }

    /// The serial of the running emulator booted from `avdName`, if any.
    public static func serial(forAVD avdName: String,
                              in running: [(serial: String, avdName: String)]) -> String? {
        running.first?.serial
    }
}
