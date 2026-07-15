import Foundation

/// Human-readable display names for Android packages, so the UI never
/// shows raw reverse-DNS identifiers to people who shouldn't have to care.
public enum AppCatalog {
    private static let known: [String: String] = [
        "jp.naver.line.android": "LINE",
        "com.aurora.store": "Aurora Store",
        "org.fdroid.fdroid": "F-Droid",
        "com.android.chrome": "Chrome",
        "com.whatsapp": "WhatsApp",
        "org.telegram.messenger": "Telegram",
        "org.thoughtcrime.securesms": "Signal",
        "com.discord": "Discord",
        "com.instagram.android": "Instagram",
        "com.facebook.katana": "Facebook",
        "com.facebook.orca": "Messenger",
        "com.twitter.android": "X",
        "com.kakao.talk": "KakaoTalk",
        "com.tencent.mm": "WeChat",
        "com.zhiliaoapp.musically": "TikTok",
        "com.google.android.youtube": "YouTube",
        "com.google.android.gm": "Gmail",
        "tw.nekomimi.nekogram": "Nekogram",
        "com.viber.voip": "Viber",
    ]

    /// Tokens that carry no identity when they end a package name.
    private static let genericTails: Set<String> = [
        "android", "app", "apps", "mobile", "client", "free", "lite", "main",
    ]

    /// Best-effort display name: catalog hit, otherwise a cleaned-up
    /// capitalisation of the most meaningful package segment.
    public static func displayName(for packageName: String) -> String {
        if let name = known[packageName] { return name }

        let segments = packageName.split(separator: ".").map(String.init)
        let meaningful = segments.reversed().first { !genericTails.contains($0.lowercased()) }
        guard let meaningful, !meaningful.isEmpty else { return packageName }
        return meaningful.prefix(1).uppercased() + meaningful.dropFirst()
    }

    private static let androidReleaseNames: [Int: String] = [
        33: "13", 34: "14", 35: "15", 36: "16",
    ]

    /// Marketing version label for an API level, e.g. 34 → "Android 14".
    /// Falls back to the raw API level when the mapping is unknown.
    public static func androidVersionName(apiLevel: Int) -> String {
        if let release = androidReleaseNames[apiLevel] {
            return "Android \(release)"
        }
        return "Android (API \(apiLevel))"
    }
}
