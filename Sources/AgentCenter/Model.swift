import SwiftUI

enum Agent: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }
    var color: Color { self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.31, green: 0.48, blue: 0.98) }
    var modeKey: String { rawValue + "Mode" }

    /// Permission presets passed to the CLI. "" keeps the user's own CLI settings.
    var modes: [(id: String, name: String)] {
        switch self {
        case .claude: [("", "Default permissions"), ("acceptEdits", "Accept edits"), ("auto", "Auto mode"),
                       ("plan", "Plan mode"), ("bypassPermissions", "Bypass permissions")]
        case .codex: [("", "Default permissions"), ("read-only", "Read only"), ("full-access", "Full access")]
        }
    }
}

struct Session: Identifiable, Hashable {
    var id: String
    let agent: Agent
    var title: String
    var cwd: String
    var updated: Date
    var branch: String? = nil
    var file: URL? = nil           // Claude transcript
    var fromDesktop = false        // Claude: started in the Claude app, so it can reopen there

    /// Agent worktrees (…/repo/.claude/worktrees/x) belong to their repo.
    var project: String {
        cwd.range(of: "/.claude/worktrees/").map { String(cwd[..<$0.lowerBound]) } ?? cwd
    }
}

struct Project: Identifiable {
    let path: String
    var count = 0
    var updated = Date.distantPast
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct Item: Identifiable {
    enum Kind { case user, assistant, tool, status, error }
    let id: String
    var kind: Kind
    var text: String
    var detail = ""
    var icon = "wrench.and.screwdriver"
    var failed = false
}

struct Approval: Identifiable {
    let id: String
    let title: String
    let detail: String
    let respond: (Bool) -> Void
}

enum RunEvent {
    case session(String)     // the agent's id for this conversation
    case item(Item)          // new or updated transcript item
    case delta(String)       // streamed assistant text
    case approval(Approval)
    case done(String?)       // error message, if it failed
}

struct Run {
    let events: AsyncStream<RunEvent>
    let stop: () -> Void
}

enum Scope: Hashable { case all, project(String) }

struct AppError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor @Observable final class AppModel {
    static let newTaskID = "agentcenter.new-task"
    private static let liveID = "agentcenter.live"

    var sessions: [Session] = []
    var scope: Scope? = .all
    var selection: String?
    var agentFilter: Agent?
    var search = ""
    var loading = false
    var transcripts: [String: [Item]] = [:]
    var approvals: [String: [Approval]] = [:]
    var problems: [Agent: String] = [:]
    private var runs: [String: () -> Void] = [:]

    let codex = Codex()

    var selected: Session? { sessions.first { $0.id == selection } }

    func isRunning(_ id: String) -> Bool { runs[id] != nil }

    var visible: [Session] {
        sessions.filter { s in
            (agentFilter == nil || s.agent == agentFilter)
                && (scope == nil || scope == .all || scope == .project(s.project))
                && (search.isEmpty || s.title.localizedCaseInsensitiveContains(search) || s.cwd.localizedCaseInsensitiveContains(search))
        }
    }

    var projects: [Project] {
        var map: [String: Project] = [:]
        for s in sessions where agentFilter == nil || s.agent == agentFilter {
            var p = map[s.project] ?? Project(path: s.project)
            p.count += 1
            p.updated = max(p.updated, s.updated)
            map[s.project] = p
        }
        return map.values.sorted { $0.updated > $1.updated }
    }

    // MARK: Loading

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        _ = await Task.detached { Env.shared }.value  // resolve the login shell off the main thread

        async let claude = Task.detached(priority: .userInitiated) { Claude.sessions() }.value
        var codexSessions: [Session] = []
        do {
            codexSessions = try await codex.sessions()
            problems[.codex] = nil
        } catch {
            problems[.codex] = error.localizedDescription
        }
        problems[.claude] = Claude.binary == nil ? Claude.missing : nil

        var all = await claude + codexSessions
        let ids = Set(all.map(\.id))
        all += sessions.filter { isRunning($0.id) && !ids.contains($0.id) }  // new runs not on disk yet
        sessions = all.sorted { $0.updated > $1.updated }
    }

    func load(_ s: Session) async {
        guard !isRunning(s.id) else { return }
        do {
            let items: [Item]
            switch s.agent {
            case .claude:
                guard let file = s.file else { return }
                items = await Task.detached(priority: .userInitiated) { Claude.transcript(file) }.value
            case .codex:
                items = try await codex.transcript(s.id)
            }
            if !isRunning(s.id) { transcripts[s.id] = items }
        } catch {
            transcripts[s.id] = [Item(id: "load-error", kind: .error, text: error.localizedDescription)]
        }
    }

    // MARK: Running

    func send(_ prompt: String, to session: Session) {
        start(prompt, agent: session.agent, cwd: session.cwd, resuming: session.id)
    }

    func start(_ prompt: String, agent: Agent, cwd: String, resuming id: String? = nil) {
        var key = id ?? "pending-" + UUID().uuidString
        let mode = UserDefaults.standard.string(forKey: agent.modeKey) ?? ""
        transcripts[key, default: []].append(Item(id: UUID().uuidString, kind: .user, text: prompt))
        let run = agent == .claude
            ? Claude.run(prompt: prompt, cwd: cwd, resume: id, mode: mode)
            : codex.run(prompt: prompt, cwd: cwd, threadID: id, mode: mode)
        runs[key] = run.stop
        if id == nil {
            sessions.insert(Session(id: key, agent: agent, title: prompt.firstLine(), cwd: cwd, updated: .now), at: 0)
            selection = key
        }
        Task {
            for await event in run.events {
                switch event {
                case .session(let real) where real != key:
                    rename(key, to: real)
                    key = real
                case .session: break
                case .item(let item): upsert(item, in: key)
                case .delta(let text): stream(text, in: key)
                case .approval(let a): approvals[key, default: []].append(a)
                case .done(let error?): upsert(Item(id: UUID().uuidString, kind: .error, text: error), in: key)
                case .done(nil): break
                }
            }
            transcripts[key]?.removeAll { $0.id == Self.liveID }
            runs[key] = nil
            approvals[key] = nil
            await refresh()
        }
    }

    func stop(_ id: String) { runs[id]?() }

    func answer(_ approval: Approval, in id: String, allow: Bool) {
        approval.respond(allow)
        approvals[id]?.removeAll { $0.id == approval.id }
    }

    private func rename(_ old: String, to new: String) {
        transcripts[new] = transcripts.removeValue(forKey: old)
        runs[new] = runs.removeValue(forKey: old)
        approvals[new] = approvals.removeValue(forKey: old)
        if let i = sessions.firstIndex(where: { $0.id == old }) { sessions[i].id = new }
        if selection == old { selection = new }
    }

    private func upsert(_ item: Item, in key: String) {
        var list = transcripts[key] ?? []
        if item.kind == .assistant { list.removeAll { $0.id == Self.liveID } }
        if let i = list.firstIndex(where: { $0.id == item.id }) { list[i] = item } else { list.append(item) }
        transcripts[key] = list
    }

    private func stream(_ text: String, in key: String) {
        if let last = transcripts[key]?.indices.last, transcripts[key]?[last].id == Self.liveID {
            transcripts[key]?[last].text += text
        } else {
            transcripts[key, default: []].append(Item(id: Self.liveID, kind: .assistant, text: text))
        }
    }

    // MARK: Handoff to the native apps

    func appURL(_ s: Session) -> URL? {
        switch s.agent {
        case .claude: s.fromDesktop ? URL(string: "claude://code/continue?session=\(s.id)") : nil
        case .codex: URL(string: "codex://threads/\(s.id)")
        }
    }

    /// Display name of the app that opens this session ("Claude", "ChatGPT", …), if installed.
    func appName(_ s: Session) -> String? {
        guard let url = appURL(s), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    func resumeInTerminal(_ s: Session) {
        switch s.agent {
        case .claude: if let b = Claude.binary { Env.openInTerminal("\(Env.quote(b)) --resume \(Env.quote(s.id))", in: s.cwd) }
        case .codex: if let b = Codex.binary { Env.openInTerminal("\(Env.quote(b)) resume \(Env.quote(s.id))", in: s.cwd) }
        }
    }
}
