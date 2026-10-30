import SwiftUI

enum Agent: String, CaseIterable, Identifiable, Codable {
    case claude, codex

    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }
    var color: Color { self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.31, green: 0.48, blue: 0.98) }
    var other: Agent { self == .claude ? .codex : .claude }
}

/// How much an agent may do without asking. "AI decides" hands approvals to the agent's own reviewer
/// (Claude's auto mode, Codex's auto_review), so you only see what it escalates.
enum Access: String, CaseIterable, Identifiable {
    case ai, ask, readOnly, full

    var id: String { rawValue }
    var name: String {
        switch self {
        case .ai: "AI decides"
        case .ask: "Ask me"
        case .readOnly: "Read only"
        case .full: "Full access"
        }
    }
    var icon: String {
        switch self {
        case .ai: "sparkles"
        case .ask: "hand.raised"
        case .readOnly: "eye"
        case .full: "bolt"
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
    var desktopID: String? = nil   // Claude: the Claude app's id, when it started this session

    /// Agent worktrees (…/repo/.claude/worktrees/x) belong to their repo.
    var project: String {
        cwd.range(of: "/.claude/worktrees/").map { String(cwd[..<$0.lowerBound]) } ?? cwd
    }
}

struct Project: Identifiable {
    let path: String
    var count = 0
    var updated = Date.distantPast
    var lastAgent: Agent?
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

/// Something an agent is waiting on: permission for one action, or answers to its questions.
struct Ask: Identifiable {
    struct Question: Identifiable {
        let id: String
        let header: String
        let text: String
        let options: [String]
    }

    let id: String
    let title: String
    var detail = ""
    var questions: [Question] = []  // empty: a plain Allow / Deny
    let respond: (_ allow: Bool, _ answers: [String: String]) -> Void  // answers by question id
}

enum RunEvent {
    case session(String)     // the agent's id for this conversation
    case item(Item)          // new or updated transcript item
    case delta(String)       // streamed assistant text
    case ask(Ask)
    case done(String?)       // error message, if it failed
}

struct Run {
    let events: AsyncStream<RunEvent>
    let stop: () -> Void
}

/// The AI's read on a session: where it stands and, if it needs you, a reply you could send.
struct Triage: Codable {
    enum State: String, Codable { case needsYou = "needs_you", failed, done, working }
    var state: State
    var summary: String
    var next: String
    var updated: Date   // the session's last activity this was written for
    var at: Date        // when it was written

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentCenter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("triage.json")
    }

    static func load() -> [String: Triage] {
        (try? JSONDecoder().decode([String: Triage].self, from: Data(contentsOf: file))) ?? [:]
    }

    static func save(_ all: [String: Triage]) {
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
    }
}

/// Where a session stands, for the inbox.
enum Status { case needsYou, running, failed, done, idle }

/// Where the AI decided to send a request. It waits for Return: nothing starts on a guess.
struct Plan {
    var request: String
    var agent: Agent
    var cwd: String
    var session: Session?   // continue this one; nil starts a new session
    var reason: String
}

/// The AI answering a question about your work, with the sessions it is talking about.
struct Answer {
    let text: String
    let sessions: [Session]
}

enum Decision {
    case run(Plan)
    case answer(Answer)
}

struct AppError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor @Observable final class AppModel {
    private static let liveID = "agentcenter.live"

    var sessions: [Session] = []
    var selection: String?  // nil shows the command home
    var search = ""
    var loading = false
    var transcripts: [String: [Item]] = [:]
    var asks: [String: [Ask]] = [:]
    var triage = Triage.load()
    var failed: Set<String> = []        // sessions whose last run here ended in an error
    var problems: [String: String] = [:]  // "claude", "codex", "ai" → what's wrong
    var draft = ""  // the command box, kept while you look at sessions
    var plan: Plan?
    var answer: Answer?
    var thinking = false
    private var runs: [String: () -> Void] = [:]
    private(set) var triaging = false

    let codex = Codex()

    var selected: Session? { sessions.first { $0.id == selection } }

    func isRunning(_ id: String) -> Bool { runs[id] != nil }

    /// Agents that are installed and answering.
    var agents: [Agent] { Agent.allCases.filter { problems[$0.rawValue] == nil } }

    var visible: [Session] {
        guard !search.isEmpty else { return sessions }
        return sessions.filter { s in
            [s.title, s.cwd, s.agent.name, triage[s.id]?.summary ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var projects: [Project] {
        var map: [String: Project] = [:]
        for s in sessions where !s.id.hasPrefix("pending-") {
            var p = map[s.project] ?? Project(path: s.project)
            p.count += 1
            if s.updated > p.updated { p.updated = s.updated; p.lastAgent = s.agent }
            map[s.project] = p
        }
        return map.values.sorted { $0.updated > $1.updated }
    }

    func status(_ s: Session) -> Status {
        if asks[s.id]?.isEmpty == false { return .needsYou }
        if isRunning(s.id) { return .running }
        if failed.contains(s.id) { return .failed }
        switch triage[s.id]?.state {
        case .needsYou?: return .needsYou
        case .failed?: return .failed
        case .done?: return .done
        case .working?: return s.updated > .now.addingTimeInterval(-600) ? .running : .idle  // active in another app
        case nil: return .idle
        }
    }

    // MARK: Loading

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        _ = await Task.detached { Env.shared }.value  // resolve the login shell off the main thread

        async let claude = Task.detached(priority: .userInitiated) { Claude.sessions() }.value
        var codexSessions = sessions.filter { $0.agent == .codex }  // keep what we had if Codex can't answer
        do {
            codexSessions = try await codex.sessions()
            problems["codex"] = nil
        } catch {
            problems["codex"] = error.localizedDescription
        }
        problems["claude"] = Claude.binary == nil ? Claude.missing : nil

        var all = await claude + codexSessions
        let ids = Set(all.map(\.id))
        all += sessions.filter { !ids.contains($0.id) && (isRunning($0.id) || $0.id.hasPrefix("pending-")) }  // not on disk (yet)
        sessions = all.sorted { $0.updated > $1.updated }
        Task { await triageRecent() }
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

    func send(_ prompt: String, to s: Session) {
        start(prompt, agent: s.agent, cwd: s.cwd, resuming: s.id)
    }

    /// Starts a new session, or continues `id`. One run per session: a request while it runs is refused.
    @discardableResult
    func start(_ prompt: String, agent: Agent, cwd: String, resuming id: String? = nil, access: Access? = nil) -> Bool {
        if let id, isRunning(id) { return false }
        var key = id ?? "pending-" + UUID().uuidString
        let access = access ?? Access(rawValue: UserDefaults.standard.string(forKey: "access") ?? "") ?? .ai
        failed.remove(key)
        transcripts[key, default: []].append(Item(id: UUID().uuidString, kind: .user, text: prompt))
        let run = agent == .claude
            ? Claude.run(prompt: prompt, cwd: cwd, resume: id, access: access)
            : codex.run(prompt: prompt, cwd: cwd, threadID: id, access: access)
        runs[key] = run.stop
        if id == nil {
            sessions.insert(Session(id: key, agent: agent, title: prompt.firstLine(), cwd: cwd, updated: .now), at: 0)
            selection = key
        }
        Task {
            var error: String?
            for await event in run.events {
                switch event {
                case .session(let real) where real != key:
                    rename(key, to: real)
                    key = real
                case .session: break
                case .item(let item): upsert(item, in: key)
                case .delta(let text): stream(text, in: key)
                case .ask(let ask): asks[key, default: []].append(ask)
                case .done(let message): error = message
                }
            }
            settle(key, error: error)
            await refresh()
        }
        return true
    }

    func stop(_ id: String) { runs[id]?() }

    /// On quit: stop every run so no agent keeps working with nobody to answer it.
    func stopAll() {
        runs.values.forEach { $0() }
        Claude.terminateAll()
        codex.reset()
    }

    func respond(_ ask: Ask, in id: String, allow: Bool, answers: [String: String] = [:]) {
        ask.respond(allow, answers)
        asks[id]?.removeAll { $0.id == ask.id }
    }

    /// Asks the other agent to review this session's uncommitted changes, read-only, in a fresh session.
    func review(_ s: Session) {
        let task = transcripts[s.id]?.first { $0.kind == .user }?.text ?? s.title
        let prompt = """
            Review the uncommitted changes in this repository (`git status`, `git diff HEAD`, and any untracked files). \
            They were made for this task: "\(task.firstLine(300))". List real bugs and risks, most severe first, \
            each with file:line and a concrete fix. Do not modify any files.
            """
        start(prompt, agent: s.agent.other, cwd: s.cwd, access: .readOnly)
    }

    /// A run ended: keep half-streamed text, record a failure, drop unanswered asks.
    private func settle(_ key: String, error: String?) {
        if let i = transcripts[key]?.firstIndex(where: { $0.id == Self.liveID }), let partial = transcripts[key]?[i] {
            transcripts[key]?[i] = Item(id: UUID().uuidString, kind: .assistant, text: partial.text)
        }
        if let error {
            transcripts[key, default: []].append(Item(id: UUID().uuidString, kind: .error, text: error))
            failed.insert(key)
        }
        runs[key] = nil
        asks[key] = nil
    }

    private func rename(_ old: String, to new: String) {
        transcripts[new] = transcripts.removeValue(forKey: old)
        runs[new] = runs.removeValue(forKey: old)
        asks[new] = asks.removeValue(forKey: old)
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

    // MARK: AI

    /// The AI decides where a request goes: which agent, which project, new or existing session.
    func route(_ request: String) async {
        plan = nil
        answer = nil
        thinking = true
        defer { thinking = false }
        let projects = Array(self.projects.prefix(20))
        let recent = Array(sessions.filter { !$0.id.hasPrefix("pending-") }.prefix(30))
        do {
            let raw = try await Brain.route(request, projects: projects, sessions: recent, triage: triage, agents: agents)
            switch Brain.decision(raw, request: request, projects: projects, sessions: recent, agents: agents) {
            case .run(let p): plan = p
            case .answer(let a): answer = a
            }
            problems["ai"] = nil
        } catch {
            answer = Answer(text: "The AI couldn't decide: \(error.localizedDescription)", sessions: [])
        }
    }

    func startPlan() {
        guard let p = plan, !p.cwd.isEmpty else { return }
        if start(p.request, agent: p.agent, cwd: p.cwd, resuming: p.session?.id), let s = p.session { selection = s.id }
        plan = nil
        draft = ""
    }

    /// Has the AI label recently active sessions (needs you / failed / done / working) with a one-line summary.
    func triageRecent() async {
        guard !triaging, UserDefaults.standard.object(forKey: "aiTriage") as? Bool ?? true, !agents.isEmpty else { return }
        let cutoff = Date.now.addingTimeInterval(-3 * 86_400)
        let due = sessions.filter { s in
            guard s.updated > cutoff, !isRunning(s.id), !s.id.hasPrefix("pending-") else { return false }
            guard let t = triage[s.id] else { return true }
            return t.updated < s.updated.addingTimeInterval(-1) && t.at < .now.addingTimeInterval(-300)  // changed, and not just checked
        }.prefix(20)
        guard !due.isEmpty else { return }
        triaging = true
        defer { triaging = false }

        var cases: [Brain.Case] = []
        for s in due {
            let last: (prompt: String, reply: String, failed: Bool)?
            if s.agent == .claude, let file = s.file {
                last = await Task.detached { Claude.lastExchange(file) }.value
            } else {
                last = try? await codex.lastExchange(s.id)
            }
            guard let last else { continue }
            cases.append(Brain.Case(session: s, prompt: last.prompt, reply: last.reply, failed: last.failed))
        }
        do {
            for (id, verdict) in try await Brain.triage(cases) {
                guard let s = due.first(where: { $0.id == id }) else { continue }
                triage[id] = Triage(state: verdict.state, summary: verdict.summary, next: verdict.next, updated: s.updated, at: .now)
            }
            Triage.save(triage)
            problems["ai"] = nil
        } catch {
            problems["ai"] = "AI summaries are off for now: \(error.localizedDescription)"
        }
    }

    // MARK: Handoff to the native apps

    func appURL(_ s: Session) -> URL? {
        switch s.agent {
        case .claude: s.desktopID.flatMap { URL(string: "claude://code/continue?session=\($0)") }
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
