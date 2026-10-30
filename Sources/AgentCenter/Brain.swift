import Foundation

/// The small decisions behind the AI-first UI: where a request should go, and what each session needs from you.
/// Made with the user's own login: Claude Haiku in safe mode (no tools, hooks, MCP or CLAUDE.md), else Codex.
enum Brain {
    struct Case {
        let session: Session
        let prompt: String
        let reply: String
        let failed: Bool
    }

    // MARK: Routing

    static func route(_ request: String, projects: [Project], sessions: [Session], triage: [String: Triage],
                      agents: [Agent]) async throws -> [String: Any] {
        let projectLines = projects.enumerated().map { i, p in
            let recent = sessions.filter { $0.project == p.path }.prefix(3).map { "\"\($0.title.firstLine(60))\" (\($0.agent.name))" }
            return "[\(i)] \(p.name) (\(p.path.abbreviatingHome)), active \(ago(p.updated)), last agent: \(p.lastAgent?.name ?? "none")"
                + (recent.isEmpty ? "" : ". Recent: " + recent.joined(separator: ", "))
        }
        let sessionLines = sessions.map { s in
            "id=\(s.id) | \(s.agent.name) | \((s.project as NSString).lastPathComponent) | \"\(s.title.firstLine(80))\" | \(ago(s.updated))"
                + (triage[s.id].map { " | \($0.state.rawValue): \($0.summary)" } ?? "")
        }
        let prompt = """
            You are the dispatcher in AgentCenter, a Mac app where a developer runs coding agents (Claude Code and Codex) \
            across projects. Decide what to do with the developer's request.

            Actions:
            - "new": start a new agent session in one project.
            - "continue": send the request to an existing session, when it clearly follows up on that session's work.
            - "answer": the developer is asking about their own work (status, what needs them, what happened). Answer in \
            `answer` from the session list below only, short and plain; put the ids of sessions you mention in `sessions`.
            - "ask": you can't tell which project they mean. Ask one short question in `answer`.

            Rules:
            - `project`: index of the project the request names or clearly concerns, from the list below; -1 if none. \
            Never invent projects.
            - `agent`: the one they name ("ask codex", "with claude"); else the last agent used in that project; \
            else \(agents.first?.rawValue ?? "claude"). Available: \(agents.map(\.rawValue).joined(separator: ", ")).
            - `session`: the session id for "continue", otherwise "".
            - `reason`: at most 12 words on why this route.

            Projects:
            \(projectLines.isEmpty ? "(none yet)" : projectLines.joined(separator: "\n"))

            Recent sessions, newest first:
            \(sessionLines.isEmpty ? "(none yet)" : sessionLines.joined(separator: "\n"))

            Developer's request:
            \(request)
            """
        return try await ask(prompt, schema: routeSchema)
    }

    /// Turns the model's answer into something safe to act on: only known projects, sessions and agents.
    static func decision(_ raw: [String: Any], request: String, projects: [Project], sessions: [Session],
                         agents: [Agent]) -> Decision {
        let text = (raw["answer"] as? String ?? "").trimmed
        let reason = (raw["reason"] as? String ?? "").trimmed
        switch raw["action"] as? String {
        case "answer", "ask":
            let linked = (raw["sessions"] as? [String] ?? []).compactMap { id in sessions.first { $0.id == id } }
            return .answer(Answer(text: text.isEmpty ? "Which project is this for?" : text, sessions: linked))
        case "continue":
            if let s = sessions.first(where: { $0.id == raw["session"] as? String }), agents.contains(s.agent) {
                return .run(Plan(request: request, agent: s.agent, cwd: s.cwd, session: s, reason: reason))
            }
            fallthrough
        default:
            let wanted = Agent(rawValue: raw["agent"] as? String ?? "")
            let agent = wanted.flatMap { agents.contains($0) ? $0 : nil } ?? agents.first ?? .claude
            let index = (raw["project"] as? NSNumber)?.intValue ?? -1
            if projects.indices.contains(index) {
                return .run(Plan(request: request, agent: agent, cwd: projects[index].path, session: nil, reason: reason))
            }
            if projects.isEmpty {
                return .run(Plan(request: request, agent: agent, cwd: "", session: nil, reason: "Choose a folder to work in."))
            }
            return .answer(Answer(text: text.isEmpty ? "Which project is this for?" : text, sessions: []))
        }
    }

    // MARK: Triage

    static func triage(_ cases: [Case]) async throws -> [String: (state: Triage.State, summary: String, next: String)] {
        guard !cases.isEmpty else { return [:] }
        let blocks = cases.map { c in
            """
            ### id: \(c.session.id)
            project: \((c.session.project as NSString).lastPathComponent) · agent: \(c.session.agent.name) · \
            last activity: \(ago(c.session.updated)) · last run errored: \(c.failed ? "yes" : "no")
            title: \(c.session.title)
            developer's last request: \(c.prompt.clipped(600))
            agent's last message: \(c.reply.clipped(1200))
            """
        }
        let prompt = """
            You triage a developer's coding-agent sessions so they know where to look first. For each session pick `state`:
            - "needs_you": the agent is waiting on the developer: it asked a question, wants a decision or approval, \
            needs credentials or access, or stopped because it is blocked.
            - "failed": the run errored, or the agent gave up without finishing.
            - "done": the agent finished what was asked and has no open question.
            - "working": it was still mid-task at its last message, with nothing asked of the developer.
            `summary`: one line, at most 80 characters, plain words, leading with the outcome or with what is needed. \
            Don't name the agent. Don't claim tests pass or work is verified unless the agent's message says so.
            `next`: for "needs_you", a short reply the developer could send (at most 60 characters); otherwise "".

            \(blocks.joined(separator: "\n\n"))
            """
        let raw = try await ask(prompt, schema: triageSchema)
        var out: [String: (state: Triage.State, summary: String, next: String)] = [:]
        for r in raw["sessions"] as? [[String: Any]] ?? [] {
            guard let id = r["id"] as? String, let state = Triage.State(rawValue: r["state"] as? String ?? "") else { continue }
            let next = state == .needsYou ? (r["next"] as? String ?? "").firstLine(80) : ""
            out[id] = (state, (r["summary"] as? String ?? "").firstLine(100), next)
        }
        return out
    }

    // MARK: Model calls

    /// One structured answer: Claude Haiku first, Codex if Claude is missing or failing (login, quota, …).
    static func ask(_ prompt: String, schema: [String: Any]) async throws -> [String: Any] {
        let schemaJSON = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        var failure = "Install Claude Code or Codex to use AI features."
        if let claude = Claude.binary {
            do {
                let out = try await Env.output(claude, ["-p", "--safe-mode", "--model", "haiku", "--tools", "",
                                                        "--no-session-persistence", "--output-format", "json",
                                                        "--json-schema", schemaJSON], input: prompt, timeout: 90)
                if let result = json(out)?["structured_output"] as? [String: Any] { return result }
                failure = json(out)?["result"] as? String ?? "Claude gave no answer."
            } catch {
                failure = error.localizedDescription
            }
        }
        if let codex = Codex.binary {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentcenter-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let schemaFile = dir.appendingPathComponent("schema.json"), answerFile = dir.appendingPathComponent("answer.json")
            try Data(schemaJSON.utf8).write(to: schemaFile)
            do {
                _ = try await Env.output(codex, ["exec", "-", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
                                                 "-c", "model_reasoning_effort=\"low\"", "--output-schema", schemaFile.path,
                                                 "-o", answerFile.path], input: prompt, cwd: dir.path, timeout: 120)
                if let result = (try? Data(contentsOf: answerFile)).flatMap(json) { return result }
                failure = "Codex gave no answer."
            } catch {
                failure = error.localizedDescription
            }
        }
        throw AppError(failure)
    }

    static let routeSchema = object([
        "action": ["type": "string", "enum": ["new", "continue", "answer", "ask"]],
        "agent": ["type": "string", "enum": ["claude", "codex"]],
        "project": ["type": "integer"],
        "session": ["type": "string"],
        "reason": ["type": "string"],
        "answer": ["type": "string"],
        "sessions": ["type": "array", "items": ["type": "string"]],
    ])

    static let triageSchema = object(["sessions": ["type": "array", "items": object([
        "id": ["type": "string"],
        "state": ["type": "string", "enum": ["needs_you", "failed", "done", "working"]],
        "summary": ["type": "string"],
        "next": ["type": "string"],
    ])]])

    /// A strict JSON-schema object: every property required, nothing extra (Codex's structured output insists).
    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys), "additionalProperties": false]
    }

    private static func ago(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
