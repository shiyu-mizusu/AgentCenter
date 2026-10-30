import AppKit

/// The user's login-shell environment. Apps opened from Finder get a bare PATH,
/// so `claude`/`codex` installed via brew, npm, etc. would otherwise be invisible.
enum Env {
    static let shared: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        if let out = run(shell, ["-ilc", "printf __ENV__; /usr/bin/env -0"], timeout: 6),
           let start = out.range(of: "__ENV__") {
            for pair in out[start.upperBound...].split(separator: "\0") {
                guard let eq = pair.firstIndex(of: "=") else { continue }
                env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
            }
        }
        let home = NSHomeDirectory()
        let known = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                     "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init) + known
        env["PATH"] = path.filter { seen.insert($0).inserted }.joined(separator: ":")
        // Started from inside a Claude Code session (e.g. `swift run`): child CLIs must not think they're nested.
        env["CLAUDECODE"] = nil
        env["CLAUDE_CODE_ENTRYPOINT"] = nil
        return env
    }()

    static func which(_ name: String, fallbacks: [String] = []) -> String? {
        let candidates = (shared["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" } + fallbacks
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a command to completion and returns its stdout (nil if it can't start).
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        kill.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a CLI off the main thread, feeding `input` on stdin, and returns its stdout.
    /// Kills it after `timeout` seconds; a failure with no output throws stderr.
    static func output(_ exe: String, _ args: [String], input: String, cwd: String = NSTemporaryDirectory(),
                       timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = shared
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                p.standardInput = stdin
                p.standardOutput = stdout
                p.standardError = stderr
                do { try p.run() } catch { return done.resume(throwing: error) }
                let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
                DispatchQueue.global().async {  // write while we read, so a large prompt can't deadlock
                    try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
                var errors = Data()
                let errorsRead = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    errors = stderr.fileHandleForReading.readDataToEndOfFile()
                    errorsRead.signal()
                }
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                errorsRead.wait()
                p.waitUntilExit()
                kill.cancel()
                if p.terminationReason == .uncaughtSignal {
                    done.resume(throwing: AppError("\((exe as NSString).lastPathComponent) took longer than \(Int(timeout))s."))
                } else if p.terminationStatus != 0, out.isEmpty {
                    done.resume(throwing: AppError(String(decoding: errors.suffix(500), as: UTF8.self).trimmed))
                } else {
                    done.resume(returning: out)
                }
            }
        }
    }

    /// Opens a Terminal window running `command` in `cwd`. A self-deleting .command file needs no Automation permission.
    static func openInTerminal(_ command: String, in cwd: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCenter-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/zsh -l\nrm -f -- \"$0\"\ncd \(quote(cwd)) || exit 1\n\(command)\n"
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            NSSound.beep()
        }
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension FileHandle {
    /// Streams newline-delimited JSON objects, parsed on a background queue. `done` runs at EOF.
    func readJSONLines(_ onObject: @escaping ([String: Any]) -> Void, done: @escaping () -> Void) {
        var buffer = Data()
        readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                if let o = json(buffer) { onObject(o) }
                done()
                return
            }
            let scanFrom = buffer.count  // earlier bytes hold no newline
            buffer.append(chunk)
            var lineStart = 0
            var from = scanFrom
            while let nl = buffer[from...].firstIndex(of: 0x0A) {
                if let o = json(buffer[lineStart..<nl]) { onObject(o) }
                lineStart = nl + 1
                from = lineStart
            }
            buffer = Data(buffer[lineStart...])
        }
    }

    /// Writes one JSON object as a line. False if it couldn't (the process is gone).
    @discardableResult
    func writeJSONLine(_ object: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return (try? write(contentsOf: data + [0x0A])) != nil
    }
}

extension Data {
    /// Calls `body` with each line until it returns false. memchr-based: `split` is slow on 100 MB+ files.
    func forEachLine(_ body: (Data) -> Bool) {
        withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count {
                let end = memchr(base + start, 0x0A, raw.count - start).map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
                if end > start, !body(self[(startIndex + start)..<(startIndex + end)]) { return }
                start = end + 1
            }
        }
    }
}

func json(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }

    func firstLine(_ limit: Int = 140) -> String {
        let line = split(whereSeparator: \.isNewline).first.map(String.init) ?? self
        return line.count > limit ? line.prefix(limit) + "…" : line
    }

    func clipped(_ limit: Int = 20_000) -> String {
        count > limit ? prefix(limit) + "\n…" : self
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// First capture group of `pattern`, if it matches.
    func capture(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
