import Foundation

/// Claude Code keeps each session as JSONL at ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl.
/// Tasks run through `claude -p` speaking stream-json both ways, so permission prompts come back to us.
enum Claude {
    static let missing = "Claude Code CLI not found. Install it from claude.com/code, or set its path in Settings."

    static var binary: String? {
        if let p = UserDefaults.standard.string(forKey: "claudePath"), !p.isEmpty { return p }
        return Env.which("claude") ?? desktopCopy
    }

    /// The copy the Claude app downloads for its Code tab, for people without the standalone CLI.
    private static var desktopCopy: String? {
        let root = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code"
        let fm = FileManager.default
        let versions = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            for build in (try? fm.contentsOfDirectory(atPath: "\(root)/\(version)")) ?? [] {
                let exe = "\(root)/\(version)/\(build)/claude.app/Contents/MacOS/claude"
                if fm.isExecutableFile(atPath: exe) { return exe }
            }
        }
        return nil
    }

    static var projects: URL {
        let config = Env.shared["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        return URL(fileURLWithPath: config).appendingPathComponent("projects")
    }

    // MARK: Listing

    private static var cache: [URL: (modified: Date, session: Session?)] = [:]
    private static let lock = NSLock()

    static func sessions() -> [Session] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
            .flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
            .filter { $0.pathExtension == "jsonl" }
        var found = [Session?](repeating: nil, count: files.count)
        found.withUnsafeMutableBufferPointer { found in
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                let file = files[i]
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                lock.lock()
                let hit = cache[file]
                lock.unlock()
                if let hit, hit.modified == modified {
                    found[i] = hit.session
                    return
                }
                found[i] = summarize(file, modified: modified)
                lock.lock()
                cache[file] = (modified, found[i])
                lock.unlock()
            }
        }
        let desktop = desktopSessions()
        return found.compactMap { s in
            guard var s, desktop[s.id]?.archived != true else { return nil }  // archived in the Claude app: hide here too
            s.desktopID = desktop[s.id]?.id
            return s
        }
    }

    /// The Claude app's own records of the sessions it started: CLI session id → its "local_…" id and archive state.
    static func desktopSessions() -> [String: (id: String, archived: Bool)] {
        let store = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
        let paths = (FileManager.default.enumerator(atPath: store)?.allObjects as? [String] ?? [])
            .filter { ($0 as NSString).lastPathComponent.hasPrefix("local_") && $0.hasSuffix(".json") }
        var out: [String: (id: String, archived: Bool)] = [:]
        for path in paths {
            guard let h = FileHandle(forReadingAtPath: "\(store)/\(path)") else { continue }
            let head = String(decoding: (try? h.read(upToCount: 8 << 10)) ?? Data(), as: UTF8.self)  // ids sit at the top
            try? h.close()
            if let cli = head.capture("\"cliSessionId\":\"([^\"]+)\""), let id = head.capture("\"sessionId\":\"(local_[^\"]+)\"") {
                out[cli] = (id, head.contains("\"isArchived\":true"))
            }
        }
        return out
    }

    /// Reads only the head (cwd, first prompt) and tail (latest title) — transcripts can be hundreds of MB.
    static func summarize(_ url: URL, modified: Date) -> Session? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var cwd: String?, branch: String?, prompt: String?
        for limit in [64 << 10, 1 << 20] where prompt == nil {  // the first prompt can sit behind a big paste
            try? h.seek(toOffset: 0)
            let head = (try? h.read(upToCount: limit)) ?? Data()
            head.forEachLine { line in
                guard let o = json(line) else { return true }
                if cwd == nil { cwd = o["cwd"] as? String }
                if branch == nil, let b = o["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { branch = b }
                if prompt == nil, o["type"] as? String == "user", o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true,
                   let text = userText((o["message"] as? [String: Any])?["content"]), !text.hasPrefix("<") {
                    prompt = text
                }
                return cwd == nil || prompt == nil
            }
            if head.count < limit { break }
        }
        guard let cwd else { return nil }

        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size - min(size, 512 << 10))
        let tail = h.readDataToEndOfFile()
        let title = record("custom-title", "customTitle", in: tail) ?? record("ai-title", "aiTitle", in: tail)
            ?? record("summary", "summary", in: tail)
        guard let name = title ?? prompt else { return nil }
        return Session(id: url.deletingPathExtension().lastPathComponent, agent: .claude, title: name.firstLine(),
                       cwd: cwd, updated: modified, branch: branch, file: url)
    }

    /// `key` of the last `{"type":"<type>",…}` line in `data` (titles get re-appended as sessions are renamed).
    private static func record(_ type: String, _ key: String, in data: Data) -> String? {
        let marker = Data("{\"type\":\"\(type)\"".utf8)
        var upper = data.endIndex
        while let r = data.range(of: marker, options: .backwards, in: data.startIndex..<upper) {
            upper = r.lowerBound
            guard r.lowerBound == data.startIndex || data[r.lowerBound - 1] == 0x0A else { continue }
            let end = data[r.lowerBound...].firstIndex(of: 0x0A) ?? data.endIndex
            if let value = json(data[r.lowerBound..<end])?[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: Transcript

    // ponytail: shows only the last 24 MB of huge sessions (some reach 500 MB); add paging if people need the start.
    static func transcript(_ url: URL) -> [Item] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0, cap: UInt64 = 24 << 20
        try? h.seek(toOffset: size > cap ? size - cap : 0)
        var data = h.readDataToEndOfFile()
        var items: [Item] = [], tools: [String: Int] = [:]
        if size > cap {
            data = data.firstIndex(of: 0x0A).map { data[($0 + 1)...] } ?? data  // drop the cut-off first line
            items.append(Item(id: "truncated", kind: .status, text: "Earlier messages in this long session are hidden."))
        }
        data.forEachLine { line in
            if let o = json(line), o["isSidechain"] as? Bool != true { apply(o, to: &items, tools: &tools) }
            return true
        }
        return items
    }

    /// Folds one user/assistant record into the transcript and returns the items it added or changed.
    @discardableResult
    static func apply(_ o: [String: Any], to items: inout [Item], tools: inout [String: Int]) -> [Item] {
        guard o["isMeta"] as? Bool != true, let message = o["message"] as? [String: Any] else { return [] }
        let uuid = o["uuid"] as? String ?? UUID().uuidString
        let content = message["content"]
        var changed: [Item] = []
        func add(_ item: Item) { items.append(item); changed.append(item) }

        switch o["type"] as? String {
        case "user":
            for block in content as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let at = tools[id] else { continue }
                items[at].detail = resultText(block["content"]).clipped()
                items[at].failed = block["is_error"] as? Bool == true
                changed.append(items[at])
            }
            if let text = userText(content) {
                if text.hasPrefix("[Request interrupted") {
                    add(Item(id: uuid, kind: .status, text: "Interrupted"))
                } else if text.hasPrefix("<") {  // hook / notification payloads injected by the harness
                    let plain = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression).trimmed
                    add(Item(id: uuid, kind: .status, text: plain.firstLine(200)))
                } else {
                    add(Item(id: uuid, kind: .user, text: text))
                }
            }
        case "assistant":
            for (i, block) in (content as? [[String: Any]] ?? []).enumerated() {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmed
                    if !text.isEmpty { add(Item(id: "\(uuid)-\(i)", kind: .assistant, text: text)) }
                case "tool_use":
                    let id = block["id"] as? String ?? "\(uuid)-\(i)"
                    let t = tool(block["name"] as? String ?? "Tool", block["input"] as? [String: Any] ?? [:])
                    tools[id] = items.count
                    add(Item(id: id, kind: .tool, text: t.title, icon: t.icon))
                default: break  // thinking
                }
            }
        default: break
        }
        return changed
    }

    /// What the person typed, minus the CLI's injected wrappers. Nil for tool results and meta records.
    static func userText(_ content: Any?) -> String? {
        var text: String
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if blocks.contains(where: { $0["type"] as? String == "image" }) { text += "\n[image]" }
        } else {
            return nil
        }
        text = text.replacingOccurrences(of: "<system-reminder>[\\s\\S]*?</system-reminder>", with: "", options: .regularExpression)
        if let command = text.capture("<command-name>([\\s\\S]*?)</command-name>") {
            text = command + " " + (text.capture("<command-args>([\\s\\S]*?)</command-args>") ?? "")
        }
        text = text.trimmed
        if text.isEmpty || text.hasPrefix("<local-command") || text.hasPrefix("Caveat: ") { return nil }
        return text
    }

    static func tool(_ name: String, _ input: [String: Any]) -> (title: String, icon: String) {
        func s(_ key: String) -> String { input[key] as? String ?? "" }
        func path(_ key: String) -> String { s(key).abbreviatingHome }
        switch name {
        case "Bash": return ("$ " + s("command"), "terminal")
        case "Read": return ("Read " + path("file_path"), "doc.text")
        case "Write": return ("Write " + path("file_path"), "square.and.pencil")
        case "Edit", "MultiEdit", "NotebookEdit": return ("Edit " + path("file_path") + path("notebook_path"), "pencil")
        case "Grep", "Glob": return ("\(name) \(s("pattern"))", "magnifyingglass")
        case "WebFetch": return ("Fetch " + s("url"), "globe")
        case "WebSearch": return ("Search " + s("query"), "globe")
        case "Task", "Agent": return ("Agent: " + s("description"), "person.2")
        case "TodoWrite": return ("Update todo list", "checklist")
        case "ExitPlanMode": return ("Plan ready", "list.bullet.clipboard")
        default:
            let short = name.hasPrefix("mcp__") ? name.components(separatedBy: "__").last ?? name : name
            let hint = input.values.lazy.compactMap { $0 as? String }.first ?? ""
            return (hint.isEmpty ? short : "\(short) \(hint)", name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver")
        }
    }

    static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.map { $0["type"] as? String == "text" ? $0["text"] as? String ?? "" : "[\($0["type"] as? String ?? "data")]" }
            .joined(separator: "\n")
    }

    /// The person's last request and the agent's last words, for AI triage. Reads only the tail of the file,
    /// widening once when screenshots or big tool results fill it.
    static func lastExchange(_ url: URL) -> (prompt: String, reply: String, failed: Bool)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        for window: UInt64 in [256 << 10, 4 << 20] {
            try? h.seek(toOffset: size - min(size, window))
            if let found = lastExchange(in: h.readDataToEndOfFile()) { return found }
            if window >= size { break }
        }
        return nil
    }

    private static func lastExchange(in tail: Data) -> (prompt: String, reply: String, failed: Bool)? {
        let marker = Data("{\"parentUuid\"".utf8)  // user/assistant records; skips the large bookkeeping lines
        var lines: [Data] = []
        tail.forEachLine { line in
            if line.starts(with: marker) { lines.append(line) }
            return true
        }
        var prompt: String?, reply: String?, toolsAfter = false
        for line in lines.reversed() where prompt == nil {
            guard let o = json(line), o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true,
                  let content = (o["message"] as? [String: Any])?["content"] else { continue }
            let blocks = content as? [[String: Any]] ?? []
            if o["type"] as? String == "assistant", reply == nil {
                let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n").trimmed
                if !text.isEmpty { reply = text } else if blocks.contains(where: { $0["type"] as? String == "tool_use" }) { toolsAfter = true }
            } else if o["type"] as? String == "user", let text = userText(content), !text.hasPrefix("<") {
                if text.hasPrefix("[Request interrupted") {
                    reply = reply ?? "(stopped by the developer)"
                } else {
                    prompt = text
                    reply = reply ?? "(no reply to this yet)"  // the request came after the agent's last words
                }
            }
        }
        // Long agentic runs can push the request out of the tail; the agent's last words still say where it stands.
        guard var reply else { return nil }
        if toolsAfter { reply += "\n\n(After this message it kept calling tools.)" }
        return (prompt ?? "(earlier in the session)", reply, false)
    }

    // MARK: Running

    private static var live = Set<Process>()  // main thread only

    /// Quitting: end every Claude process this app started.
    static func terminateAll() {
        live.forEach { $0.terminate() }
    }

    static func run(prompt: String, cwd: String, resume: String?, access: Access) -> Run {
        let (events, out) = AsyncStream.makeStream(of: RunEvent.self)
        guard let exe = binary else {
            out.yield(.done(missing))
            out.finish()
            return Run(events: events, stop: {})
        }
        let permissions: [String]
        switch access {
        case .ai: permissions = ["--permission-mode", "auto"]
        case .ask: permissions = []  // the person's own default; prompts come to us over stdio
        case .readOnly: permissions = ["--permission-mode", "plan", "--allowedTools",
                                       "Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(git show:*)"]
        case .full: permissions = ["--permission-mode", "bypassPermissions"]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = Env.shared
        p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--include-partial-messages", "--permission-prompt-tool", "stdio"]
            + permissions
            + (resume.map { ["--resume", $0] } ?? [])
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        let stdin = input.fileHandleForWriting

        // Everything below runs on the main queue, so this state needs no locking.
        var items: [Item] = [], tools: [String: Int] = [:]
        var stderr = "", finished = false, stopped = false

        func finish(_ error: String?) {
            guard !finished else { return }
            finished = true
            live.remove(p)
            try? stdin.close()
            if stopped, !items.contains(where: { $0.text == "Interrupted" }) {  // the CLI usually says so itself
                out.yield(.item(Item(id: UUID().uuidString, kind: .status, text: "Stopped")))
            }
            out.yield(.done(stopped ? nil : error))
            out.finish()
        }

        func handle(_ o: [String: Any]) {
            switch o["type"] as? String {
            case "system":
                if o["subtype"] as? String == "init", let id = o["session_id"] as? String { out.yield(.session(id)) }
            case "stream_event":
                let delta = (o["event"] as? [String: Any])?["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String { out.yield(.delta(text)) }
            case "assistant", "user":
                guard !(o["parent_tool_use_id"] is String) else { return }  // a subagent's inner turns
                for item in apply(o, to: &items, tools: &tools) { out.yield(.item(item)) }
            case "control_request":
                guard let rid = o["request_id"] as? String, let req = o["request"] as? [String: Any],
                      req["subtype"] as? String == "can_use_tool" else { return }
                let name = req["tool_name"] as? String ?? "tool"
                let toolInput = req["input"] as? [String: Any] ?? [:]
                func reply(_ allow: Bool, input: [String: Any]) {
                    let decision: [String: Any] = allow ? ["behavior": "allow", "updatedInput": input]
                        : ["behavior": "deny", "message": "The user declined this in AgentCenter."]
                    stdin.writeJSONLine(["type": "control_response",
                                         "response": ["subtype": "success", "request_id": rid, "response": decision]])
                }
                if name == "AskUserQuestion" {  // answered by passing `answers` (question text → choice) back in the input
                    let questions = (toolInput["questions"] as? [[String: Any]] ?? []).map { q in
                        Ask.Question(id: q["question"] as? String ?? "", header: q["header"] as? String ?? "",
                                     text: q["question"] as? String ?? "",
                                     options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                                     multi: q["multiSelect"] as? Bool == true)
                    }
                    out.yield(.ask(Ask(id: rid, title: "Claude has a question", questions: questions) { allow, answers in
                        var input = toolInput
                        input["answers"] = answers
                        reply(allow, input: input)
                    }))
                    return
                }
                let t = tool(name, toolInput)
                let detail = req["description"] as? String ?? toolInput["plan"] as? String ?? ""
                out.yield(.ask(Ask(id: rid, title: t.title, detail: detail) { allow, _ in reply(allow, input: toolInput) }))
            case "result":
                let ok = o["subtype"] as? String == "success" && o["is_error"] as? Bool != true
                finish(ok ? nil : o["result"] as? String ?? (o["errors"] as? [String])?.joined(separator: "\n") ?? "Claude stopped with an error.")
            default: break
            }
        }

        errors.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { stderr += String(decoding: chunk, as: UTF8.self) }
        }
        output.fileHandleForReading.readJSONLines({ o in
            DispatchQueue.main.async { handle(o) }
        }, done: {
            p.waitUntilExit()
            DispatchQueue.main.async {
                let why = stderr.trimmed.isEmpty ? "" : "\n" + String(stderr.trimmed.suffix(800))
                finish("Claude Code exited (status \(p.terminationStatus)).\(why)")
            }
        })

        do {
            try p.run()
        } catch {
            out.yield(.done("Couldn't start Claude Code: \(error.localizedDescription)"))
            out.finish()
            return Run(events: events, stop: {})
        }
        live.insert(p)
        stdin.writeJSONLine(["type": "user", "session_id": "", "parent_tool_use_id": NSNull(),
                             "message": ["role": "user", "content": [["type": "text", "text": prompt]]]])

        return Run(events: events, stop: {
            stopped = true
            stdin.writeJSONLine(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        })
    }
}
