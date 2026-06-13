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
        // The hard-link count is also numeric, so take the LAST parseable
        // number — the size column comes after it, and the date/time tokens
        // contain '-'/':' so they never parse as integers.
        let parts = output.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var size: Int64? = nil
        for part in parts {
            if let bytes = Int64(part), bytes >= 0 { size = bytes }
        }
        return size
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
}
