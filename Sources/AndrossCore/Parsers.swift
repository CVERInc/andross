import Foundation

/// Pure output parsers for Android tooling (avdmanager / adb / pm / du).
/// Kept side-effect free so they can be unit-tested without a device.
public enum AndrossParse {
    /// Parse `avdmanager list avd` output into AVD names.
    public static func avdNames(from output: String) -> [String] {
        var names: [String] = []
        for line in output.components(separatedBy: .newlines) {
            guard let range = line.range(of: "Name:") else { continue }
            let name = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    /// Parse `adb devices` output into emulator serials (e.g. "emulator-5554").
    /// Only returns devices in the "device" state (booted enough for adb).
    public static func emulatorSerials(from output: String) -> [String] {
        var serials: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  parts[0].hasPrefix("emulator-"),
                  parts[1].trimmingCharacters(in: .whitespaces) == "device" else { continue }
            serials.append(String(parts[0]))
        }
        return serials
    }

    /// Parse `pm list users` output into user records.
    /// Lines look like: `UserInfo{0:Owner:c13} running` or `UserInfo{10:work:410}`.
    public static func users(from output: String) -> [(userId: Int, name: String, isRunning: Bool)] {
        var list: [(Int, String, Bool)] = []
        for line in output.components(separatedBy: .newlines) {
            guard line.contains("UserInfo{"),
                  let start = line.firstIndex(of: "{"),
                  let end = line.firstIndex(of: "}") else { continue }
            let info = String(line[line.index(after: start)..<end])
            let parts = info.components(separatedBy: ":")
            guard parts.count >= 2, let userId = Int(parts[0]) else { continue }
            list.append((userId, parts[1], line.contains("running")))
        }
        return list
    }

    /// Parse `pm create-user <name>` output into the new user id.
    /// Success output: `Success: created user id 10`.
    public static func createdUserId(from output: String) -> Int? {
        guard let match = output.range(of: #"Success: created user id (\d+)"#, options: .regularExpression) else {
            return nil
        }
        let digits = output[match].filter { $0.isNumber }
        return Int(digits)
    }

    /// Parse `du -sk <path>` output into bytes (first column is kilobytes).
    public static func duBytes(from output: String) -> Int64? {
        let first = output
            .components(separatedBy: .whitespacesAndNewlines)
            .first { !$0.isEmpty }
        guard let first, let kb = Int64(first) else { return nil }
        return kb * 1024
    }

    /// Parse `pm list packages [...]` output into package names.
    public static func packageNames(from output: String) -> [String] {
        var names: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("package:") else { continue }
            let name = String(trimmed.dropFirst("package:".count))
            if !name.isEmpty { names.append(name) }
        }
        return names.sorted()
    }

    /// Parse `pm path <pkg>` output into APK file paths on the device.
    public static func apkPaths(from output: String) -> [String] {
        var paths: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("package:") else { continue }
            let path = String(trimmed.dropFirst("package:".count))
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// Parse `ls -l <file>` output into the file size column, if present.
    public static func lsFileSize(from output: String) -> Int64? {
        // `ls -l` on Android: -rw-r--r-- 1 system system 123456 2026-06-13 10:00 base.apk
        // The size column sits between the link/owner columns and the
        // date/time stamp. A filename can itself be purely numeric (e.g.
        // `.../999999`), so we must NOT just take the last integer — that
        // would return the name. The date token always contains '-' and the
        // time ':', so we take the LAST integer that appears *before* the
        // first date/time-shaped token on the line.
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            // Only trust well-formed long-listing rows. A real row leads with
            // a 10-char mode string (e.g. "-rw-r--r--"); error rows ("ls: …")
            // and bare output never match, so they correctly yield nil.
            guard let mode = parts.first, mode.count >= 10,
                  "-dlpcbs".contains(mode.first!) else { continue }
            var size: Int64? = nil
            for part in parts.dropFirst() {
                // Stop at the date/time stamp.
                if part.contains("-") || part.contains(":") { break }
                if let bytes = Int64(part), bytes >= 0 { size = bytes }
            }
            if let size { return size }
        }
        return nil
    }

    /// Parse `getprop sys.boot_completed` output ("1" when fully booted).
    public static func bootCompleted(from output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Parse the focused package out of a `dumpsys window` mCurrentFocus line:
    /// `mCurrentFocus=Window{1fafa71 u0 com.example.app/com.example.app.MainActivity}`
    public static func focusedPackage(from output: String) -> String? {
        guard let line = output.components(separatedBy: .newlines)
            .first(where: { $0.contains("mCurrentFocus=") }) else { return nil }
        // Last space-separated token inside the braces, before the closing }.
        guard let braceStart = line.firstIndex(of: "{"),
              let braceEnd = line.lastIndex(of: "}") else { return nil }
        let inner = line[line.index(after: braceStart)..<braceEnd]
        guard let component = inner.split(separator: " ").last else { return nil }
        let package = component.split(separator: "/").first.map(String.init)
        return (package?.isEmpty == false) ? package : nil
    }

    /// Parse `cmd package resolve-activity --brief …` output into the full
    /// component (last line is `com.pkg/com.pkg.SomeActivity`).
    public static func resolvedComponent(from output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.last, last.contains("/") else { return nil }
        return last
    }

    /// Package part of a resolved HOME component — the default launcher.
    public static func launcherPackage(from output: String) -> String? {
        guard let component = resolvedComponent(from: output) else { return nil }
        let package = component.split(separator: "/").first.map(String.init)
        return (package?.isEmpty == false) ? package : nil
    }

    /// A validated `screencap` raw-frame header.
    public struct ScreencapHeader: Equatable, Sendable {
        public let width: Int
        public let height: Int
        /// Number of RGBA bytes that should follow the 12-byte header.
        public let pixelByteCount: Int
    }

    /// Largest frame we will trust from a `screencap` header. A booting or
    /// misbehaving device can emit garbage where the header should be; without
    /// a ceiling `width * height * 4` overflows `Int` (crash) or asks us to
    /// buffer gigabytes. 16384×16384 RGBA ≈ 1 GiB — comfortably above any real
    /// phone/tablet panel, so anything larger is corruption, not a frame.
    public static let maxScreencapDimension = 16384

    /// Parse the 12-byte little-endian `screencap` header (width, height,
    /// pixel-format) and validate it. Returns nil — never crashes or overflows
    /// — when the bytes are short, zero, or implausibly large. Byte-wise decode
    /// avoids the alignment requirement of `load(as: UInt32.self)`, which is
    /// undefined behaviour on the unaligned `Data` a pipe hands back.
    public static func screencapHeader(from header: [UInt8]) -> ScreencapHeader? {
        guard header.count >= 12 else { return nil }
        func u32(_ offset: Int) -> Int {
            Int(header[offset])
                | Int(header[offset + 1]) << 8
                | Int(header[offset + 2]) << 16
                | Int(header[offset + 3]) << 24
        }
        let width = u32(0)
        let height = u32(4)
        guard width > 0, height > 0,
              width <= maxScreencapDimension, height <= maxScreencapDimension else { return nil }
        // width/height are each ≤ 16384, so width * height * 4 ≤ ~1.07e9 —
        // fits an Int with no overflow risk on any supported platform.
        return ScreencapHeader(width: width, height: height, pixelByteCount: width * height * 4)
    }

    /// Distil an emulator's stderr into a one-line, human-readable failure
    /// reason. The emulator decorates each log line with a severity and a pipe —
    /// `FATAL        | Your device does not have enough disk space to run avd: X`
    /// — or aborts with `PANIC: Cannot find AVD system path`. We surface the most
    /// telling line, stripped of that decoration, so a person sees the cause
    /// without reading the whole log. Returns a generic fallback when nothing in
    /// the text stands out as the reason.
    public static func emulatorFailureReason(from stderr: String) -> String {
        let lines = stderr.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Severity order: an explicit PANIC/FATAL beats a generic error line.
        // Within a severity, take the *first* match — the emulator prints the
        // root cause first and follows it with notes/context that read as noise.
        for needle in ["PANIC:", "FATAL", "ERROR", "Error:"] {
            if let hit = lines.first(where: { $0.range(of: needle) != nil }) {
                return cleanEmulatorLine(hit)
            }
        }
        return "The phone's engine stopped right after starting."
    }

    /// Strip the `LEVEL | ` decoration and severity label off one emulator log
    /// line, leaving just the human-meaningful message.
    private static func cleanEmulatorLine(_ raw: String) -> String {
        var line = raw
        // Drop the leading `LEVEL   | ` the emulator prepends to each log line.
        if let pipe = line.range(of: "| ") {
            line = String(line[pipe.upperBound...])
        }
        // Drop a leading severity label if that's what matched (PANIC lines
        // carry no pipe, so the label survives the step above).
        for label in ["PANIC:", "FATAL:", "ERROR:", "Error:"] where line.hasPrefix(label) {
            line = String(line.dropFirst(label.count))
        }
        line = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "`", with: "")
        return line.isEmpty ? raw : line
    }
}
