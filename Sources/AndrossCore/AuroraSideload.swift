import Foundation

/// The decisions behind sideloading Aurora Store onto an AOSP+Aurora phone,
/// kept pure so they can be unit tested without curl, adb or a booted device.
public enum AuroraSideload {
    public static let sourceURL = "https://files.auroraoss.com/AuroraStore/Stable/AuroraStore-Stable.apk"

    /// Where the APK waiting to be installed on `avdName`'s first boot lives.
    /// One file per AVD, so booting a different phone never picks it up.
    public static func pendingAPKURL(forAVD avdName: String, in tmpDir: URL) -> URL {
        let safeName = avdName.replacingOccurrences(of: "/", with: "_")
        return tmpDir
            .appendingPathComponent("aurora-pending", isDirectory: true)
            .appendingPathComponent("\(safeName).apk")
    }

    /// The curl invocation that fetches the APK to `destination`. `-f` makes an
    /// HTTP 4xx/5xx a non-zero exit instead of saving the error page as the APK.
    public static func downloadCommand(to destination: URL) -> [String] {
        ["curl", "-f", "-L", "-o", destination.path, sourceURL]
    }

    /// Whether a downloaded payload can be handed to `adb install`: an APK is a
    /// zip, so anything not starting with the local-file-header magic (an HTML
    /// error or captive-portal page, an empty file) is rejected.
    public static func looksLikeAPK(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    /// The serial of the running emulator booted from `avdName`, if any.
    public static func serial(forAVD avdName: String,
                              in running: [(serial: String, avdName: String)]) -> String? {
        running.first(where: { $0.avdName == avdName })?.serial
    }
}
