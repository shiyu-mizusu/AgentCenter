import Foundation

/// Codex is driven through `codex app-server`: JSON-RPC over stdio, the same API the Codex app
/// and IDE extensions use. It owns Codex's storage, so we never read its databases directly.
@MainActor final class Codex {
    static var binary: String? {
        if let p = UserDefaults.standard.string(forKey: "codexPath"), !p.isEmpty { return p }
        let bundled = ["ChatGPT", "Codex"].map { "/Applications/\($0).app/Contents/Resources/codex-cli/bin/codex" }
        return Env.which("codex", fallbacks: bundled + ["/Applications/Codex.app/Contents/Resources/codex"])
    }

    private typealias Listener = (_ method: String, _ params: [String: Any], _ requestID: Any?) -> Void

    private var process: Process?
    private var stdin: FileHandle?
    private var ready: Task<Void, Error>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var listeners: [String: Listener] = [:]  // by thread id

    // MARK: JSON-RPC plumbing

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if ready == nil || process?.isRunning != true { ready = Task { try await boot() } }
        try await ready!.value
        return try await call(method, params)
    }

    /// Stops the server; the next request starts a fresh one (e.g. after the CLI path changes).
    func reset() {
        process?.terminate()
        ready = nil
    }

    private func boot() async throws {
        guard let exe = Self.binary else {
            throw AppError("Codex not found. Install the ChatGPT (Codex) app or `npm i -g @openai/codex`, or set its path in Settings.")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["app-server"]
        p.environment = Env.shared
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        stdin = input.fileHandleForWriting
        output.fileHandleForReading.readJSONLines({ o in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(o) } }
        }, done: {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.closed(p) } }
        })
        _ = try await call("initialize", ["clientInfo": ["name": "agentcenter", "title": "AgentCenter", "version": "0.1.0"],
                                          "capabilities": NSNull()])
        stdin?.writeJSONLine(["method": "initialized"])
    }

    private func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            stdin?.writeJSONLine(["id": id, "method": method, "params": params])
        }
    }

    private func receive(_ o: [String: Any]) {
        guard let method = o["method"] as? String else {  // a response to one of our calls
            guard let id = (o["id"] as? NSNumber)?.intValue, let c = pending.removeValue(forKey: id) else { return }
            if let e = o["error"] as? [String: Any] {
                c.resume(throwing: AppError(e["message"] as? String ?? "Codex error"))
            } else {
                c.resume(returning: o["result"] as? [String: Any] ?? [:])
            }
            return
        }
        let params = o["params"] as? [String: Any] ?? [:]
        let thread = params["threadId"] as? String ?? (params["thread"] as? [String: Any])?["id"] as? String
        if let thread, let listener = listeners[thread] {
            listener(method, params, o["id"])
        } else if let id = o["id"] {  // a server request nobody here can answer
            stdin?.writeJSONLine(["id": id, "error": ["code": -32601, "message": "Not supported by AgentCenter"]])
        }
    }

    private func closed(_ p: Process) {
        guard p === process else { return }
        process = nil
        ready = nil
        pending.values.forEach { $0.resume(throwing: AppError("Codex app-server stopped.")) }
        pending = [:]
        listeners.values.forEach { $0("agentcenter/closed", [:], nil) }
    }

    // MARK: Sessions

    func sessions() async throws -> [Session] {
        var out: [Session] = []
        var cursor: Any = NSNull()
        repeat {
            // The default source filter (interactive threads) matches what the Codex app shows.
            let r = try await request("thread/list", ["limit": 200, "sortKey": "updated_at", "cursor": cursor, "useStateDbOnly": true])
            for t in r["data"] as? [[String: Any]] ?? [] {
                guard let id = t["id"] as? String, let cwd = t["cwd"] as? String else { continue }
                let name = (t["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? t["preview"] as? String ?? "Untitled"
                let updated = (t["updatedAt"] as? NSNumber)?.doubleValue ?? 0
                out.append(Session(id: id, agent: .codex, title: name.firstLine(), cwd: cwd,
                                   updated: Date(timeIntervalSince1970: updated),
                                   branch: (t["gitInfo"] as? [String: Any])?["branch"] as? String))
            }
            cursor = r["nextCursor"] as? String ?? NSNull()
        } while cursor is String && out.count < 5000
        return out
    }

    func transcript(_ id: String) async throws -> [Item] {
        var items: [Item] = []
        var cursor: Any = NSNull()
        repeat {
            let r = try await request("thread/turns/list", ["threadId": id, "limit": 50, "sortDirection": "asc",
                                                            "itemsView": "full", "cursor": cursor])
            for turn in r["data"] as? [[String: Any]] ?? [] {
                items += (turn["items"] as? [[String: Any]] ?? []).compactMap(Self.item)
                if let error = (turn["error"] as? [String: Any])?["message"] as? String {
                    items.append(Item(id: "\(turn["id"] ?? "")-error", kind: .error, text: error))
                }
            }
            cursor = r["nextCursor"] as? String ?? NSNull()
        } while cursor is String
        return items
    }

    // MARK: Running

    func run(prompt: String, cwd: String, threadID: String?, mode: String) -> Run {
        let (events, out) = AsyncStream.makeStream(of: RunEvent.self)
        var thread = threadID, turn: String?, finished = false

        func finish(_ error: String?) {
            guard !finished else { return }
            finished = true
            if let thread { listeners[thread] = nil }
            out.yield(.done(error))
            out.finish()
        }

        func listen(_ method: String, _ p: [String: Any], _ requestID: Any?) {
            switch method {
            case "item/started", "item/completed":
                guard let raw = p["item"] as? [String: Any], let item = Self.item(raw), item.kind != .user,
                      method == "item/completed" || item.kind != .assistant else { return }  // text arrives as deltas
                out.yield(.item(item))
            case "item/agentMessage/delta":
                if let delta = p["delta"] as? String { out.yield(.delta(delta)) }
            case "error":
                if p["willRetry"] as? Bool != true, let message = (p["error"] as? [String: Any])?["message"] as? String {
                    out.yield(.item(Item(id: UUID().uuidString, kind: .error, text: message)))
                }
            case "turn/completed":
                let t = p["turn"] as? [String: Any]
                switch t?["status"] as? String {
                case "failed": finish((t?["error"] as? [String: Any])?["message"] as? String ?? "Codex turn failed.")
                case "interrupted": out.yield(.item(Item(id: UUID().uuidString, kind: .status, text: "Stopped"))); finish(nil)
                default: finish(nil)
                }
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                guard let requestID else { return }
                let title = method.contains("command") ? "$ " + Self.unwrap(p["command"] as? String ?? "command") : "Apply file changes"
                out.yield(.approval(Approval(id: "\(requestID)", title: title, detail: p["reason"] as? String ?? "") { [weak self] allow in
                    self?.stdin?.writeJSONLine(["id": requestID, "result": ["decision": allow ? "accept" : "decline"]])
                }))
            case "agentcenter/closed":
                finish("Codex app-server stopped.")
            default:
                if let requestID { stdin?.writeJSONLine(["id": requestID, "error": ["code": -32601, "message": "Not supported by AgentCenter"]]) }
            }
        }

        Task {
            do {
                var options: [String: Any] = [:]
                switch mode {
                case "read-only": options = ["sandbox": "read-only", "approvalPolicy": "on-request"]
                case "full-access": options = ["sandbox": "danger-full-access", "approvalPolicy": "never"]
                default: break
                }
                if let id = thread {
                    _ = try await request("thread/resume", options.merging(["threadId": id, "excludeTurns": true]) { $1 })
                } else {
                    let r = try await request("thread/start", options.merging(["cwd": cwd]) { $1 })
                    thread = (r["thread"] as? [String: Any])?["id"] as? String
                }
                guard let id = thread else { throw AppError("Codex didn't return a thread id.") }
                listeners[id] = listen
                out.yield(.session(id))
                let r = try await request("turn/start", ["threadId": id, "input": [["type": "text", "text": prompt, "text_elements": []]]])
                turn = (r["turn"] as? [String: Any])?["id"] as? String
            } catch {
                finish(error.localizedDescription)
            }
        }

        return Run(events: events, stop: { [weak self] in
            guard let thread, let turn else { return }
            Task { _ = try? await self?.request("turn/interrupt", ["threadId": thread, "turnId": turn]) }
        })
    }

    // MARK: Items

    nonisolated static func item(_ o: [String: Any]) -> Item? {
        let id = o["id"] as? String ?? UUID().uuidString
        func s(_ key: String) -> String { o[key] as? String ?? "" }
        switch o["type"] as? String {
        case "userMessage":
            let parts = (o["content"] as? [[String: Any]] ?? []).compactMap { c -> String? in
                switch c["type"] as? String {
                case "text": return c["text"] as? String
                case "image", "localImage": return "[image]"
                default: return nil
                }
            }
            let text = parts.joined(separator: "\n").trimmed
            return text.isEmpty ? nil : Item(id: id, kind: .user, text: text)
        case "agentMessage", "plan":
            return s("text").trimmed.isEmpty ? nil : Item(id: id, kind: .assistant, text: s("text").trimmed)
        case "commandExecution":
            let code = (o["exitCode"] as? NSNumber)?.intValue
            return Item(id: id, kind: .tool, text: "$ " + unwrap(s("command")), detail: s("aggregatedOutput").clipped(),
                        icon: "terminal", failed: code != nil && code != 0)
        case "fileChange":
            let changes = o["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { ($0["path"] as? String)?.abbreviatingHome }
            return Item(id: id, kind: .tool, text: "Edit " + paths.joined(separator: ", "),
                        detail: changes.compactMap { $0["diff"] as? String }.joined(separator: "\n").clipped(), icon: "pencil")
        case "mcpToolCall":
            let result = o["result"] ?? o["error"]
            return Item(id: id, kind: .tool, text: "\(s("server")) · \(s("tool"))", detail: describe(result).clipped(),
                        icon: "puzzlepiece.extension", failed: o["error"] is [String: Any])
        case "dynamicToolCall": return Item(id: id, kind: .tool, text: s("tool"))
        case "webSearch": return Item(id: id, kind: .tool, text: "Search " + s("query"), icon: "globe")
        case "imageView": return Item(id: id, kind: .tool, text: "View " + s("path").abbreviatingHome, icon: "photo")
        case "imageGeneration": return Item(id: id, kind: .tool, text: "Generate image", icon: "photo")
        case "collabAgentToolCall", "subAgentActivity": return Item(id: id, kind: .tool, text: "Sub-agent", icon: "person.2")
        case "contextCompaction": return Item(id: id, kind: .status, text: "Context compacted")
        case "enteredReviewMode": return Item(id: id, kind: .status, text: "Review started")
        default: return nil  // reasoning, hooks, …
        }
    }

    /// "/bin/zsh -lc 'ls -la'" → "ls -la"
    nonisolated static func unwrap(_ command: String) -> String {
        guard let r = command.range(of: "^\\S*(ba|z)?sh -l?c ", options: .regularExpression) else { return command }
        var rest = String(command[r.upperBound...])
        if rest.count >= 2, let q = rest.first, q == rest.last, q == "'" || q == "\"" { rest = String(rest.dropFirst().dropLast()) }
        return rest
    }

    nonisolated private static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let content = (value as? [String: Any])?["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}
