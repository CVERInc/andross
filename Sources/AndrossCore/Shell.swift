import Foundation

/// Minimal process runner. Resolves tools via `/usr/bin/env` so it honours the
/// user's PATH (node, npm, git, …).
public enum Shell {
    nonisolated(unsafe) private static var cachedPath: String?

    private static func resolvedPath() -> String {
        if let cachedPath { return cachedPath }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: shell)
        probe.arguments = ["-ilc", "printf %s \"$PATH\""]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = Pipe()
        var result = ""
        if (try? probe.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.isEmpty {
            let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                          "/usr/sbin", "/sbin", NSHomeDirectory() + "/.volta/bin"]
            let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
            result = (extras + [existing]).joined(separator: ":")
        }
        cachedPath = result
        return result
    }

    private static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = resolvedPath()
        return env
    }

    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var ok: Bool { status == 0 }
    }

    /// Run a command and capture its output.
    @discardableResult
    public static func run(_ args: [String], cwd: URL? = nil, stdin: String? = nil) -> Result {
        guard let first = args.first else {
            return Result(status: -1, stdout: "", stderr: "empty command")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = childEnvironment()
        if let cwd { process.currentDirectoryURL = cwd }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        let collector = OutputCollector()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "andross.shell.read", attributes: .concurrent)
        group.enter()
        queue.async {
            collector.setOut(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        queue.async {
            collector.setErr(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: "\(first): \(error.localizedDescription)")
        }
        
        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        group.wait()

        return Result(
            status: process.terminationStatus,
            stdout: collector.outString,
            stderr: collector.errString
        )
    }

    private static let ansiRegex =
        try! NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]")

    static func cleanLine(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r", with: "")
        t = ansiRegex.stringByReplacingMatches(
            in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        let scalars = t.unicodeScalars.filter { sc in
            !(sc.value >= 0x2800 && sc.value <= 0x28FF) && (sc.value >= 0x20 || sc.value == 9)
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    /// Run a command and stream output line-by-line to UI.
    @discardableResult
    public static func runStreaming(
        _ args: [String], cwd: URL? = nil, stdin: String? = nil,
        onLine: @escaping @Sendable (_ text: String, _ transient: Bool) -> Void
    ) -> Result {
        guard let first = args.first else {
            return Result(status: -1, stdout: "", stderr: "empty command")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = childEnvironment()
        if let cwd { process.currentDirectoryURL = cwd }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        let acc = OutputCollector()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "andross.shell.stream", attributes: .concurrent)

        func pump(_ handle: FileHandle, isErr: Bool) {
            group.enter()
            queue.async {
                var lineBuf = Data()
                func flush(transient: Bool) {
                    let text = cleanLine(String(decoding: lineBuf, as: UTF8.self))
                    lineBuf.removeAll(keepingCapacity: true)
                    if !text.isEmpty { onLine(text, transient) }
                }
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    if isErr { acc.appendErr(chunk) } else { acc.appendOut(chunk) }
                    for byte in chunk {
                        switch byte {
                        case 0x0A: flush(transient: false)
                        case 0x0D: flush(transient: true)
                        default: lineBuf.append(byte)
                        }
                    }
                }
                flush(transient: false)
                group.leave()
            }
        }

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: "\(first): \(error.localizedDescription)")
        }
        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        pump(outPipe.fileHandleForReading, isErr: false)
        pump(errPipe.fileHandleForReading, isErr: true)
        process.waitUntilExit()
        group.wait()
        return Result(status: process.terminationStatus, stdout: acc.outString, stderr: acc.errString)
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setOut(_ d: Data) { lock.lock(); out = d; lock.unlock() }
    func setErr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }

    var outString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var errString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}
