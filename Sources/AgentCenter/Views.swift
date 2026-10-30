import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Inbox()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } detail: {
            if let session = model.selected {
                SessionView(session: session)
                    .id(session.id)
            } else {
                Home()
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search")
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refresh()
                if let s = model.selected { await model.load(s) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.stopAll()
        }
    }
}

// MARK: - Inbox

/// Sessions sorted by what they need from you, not by folder.
struct Inbox: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let groups = Dictionary(grouping: model.visible) { model.status($0) }
        let needsYou = (groups[.needsYou] ?? []) + (groups[.failed] ?? [])
        let running = groups[.running] ?? []
        let recent = (groups[.done] ?? []) + (groups[.idle] ?? [])
        List(selection: $model.selection) {
            if !needsYou.isEmpty { Section("Needs you") { rows(needsYou) } }
            if !running.isEmpty { Section("Running") { rows(running) } }
            Section("Recent") { rows(recent.sorted { $0.updated > $1.updated }) }
        }
        .overlay {
            if model.visible.isEmpty {
                if model.loading {
                    ProgressView()
                } else {
                    ContentUnavailableView(model.search.isEmpty ? "No Sessions Yet" : "No Results", systemImage: "tray")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.problems.sorted(by: { $0.key < $1.key }), id: \.key) { _, problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.multicolor)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, model.problems.isEmpty ? 0 : 10)
        }
        .toolbar {
            ToolbarItem {
                Button { model.selection = nil } label: { Label("New Task", systemImage: "square.and.pencil") }
                    .help("New task (⌘N)")
            }
        }
    }

    private func rows(_ sessions: [Session]) -> some View {
        ForEach(sessions) { s in
            InboxRow(session: s)
                .tag(s.id)
                .contextMenu { SessionActions(session: s, menu: true) }
        }
    }
}

struct InboxRow: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusIcon(status: model.status(session))
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .lineLimit(2)
                if let summary = model.triage[session.id]?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    AgentBadge(agent: session.agent)
                    Text((session.project as NSString).lastPathComponent)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.updated.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct StatusIcon: View {
    let status: Status

    var body: some View {
        switch status {
        case .needsYou: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .running: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

struct AgentBadge: View {
    let agent: Agent

    var body: some View {
        Text(agent.name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(agent.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(agent.color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Home

/// One box for everything: say what you want; the AI picks the agent, project and session.
struct Home: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let waiting = model.sessions.filter { model.status($0) == .needsYou }.prefix(4)
        ScrollView {
            VStack(spacing: 18) {
                Text("What should we work on?")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.top, 80)
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Describe a task, or ask about your work…", text: $model.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .lineLimit(1...8)
                        .focused($focused)
                        .onSubmit(submit)
                    if model.thinking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: submit) { Image(systemName: "arrow.up").fontWeight(.semibold) }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.circle)
                            .disabled(model.draft.trimmed.isEmpty)
                    }
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)

                if let plan = model.plan { PlanCard(plan: plan) }
                if let answer = model.answer { AnswerCard(answer: answer) }

                if !waiting.isEmpty, model.plan == nil, model.answer == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Needs you")
                            .font(.headline)
                        ForEach(Array(waiting)) { NeedsYouRow(session: $0) }
                    }
                    .padding(.top, 10)
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { focused = true }
        .onChange(of: model.draft) {  // editing the request makes the proposed route stale
            if let plan = model.plan, plan.request != model.draft.trimmed { model.plan = nil }
        }
    }

    /// Return routes the request; Return again (unchanged text) starts the plan the AI proposed.
    private func submit() {
        let text = model.draft.trimmed
        guard !text.isEmpty, !model.thinking else { return }
        if let plan = model.plan, plan.request == text {
            model.startPlan()  // no-op until a folder is picked
        } else {
            Task { await model.route(text) }
        }
    }
}

/// The AI's routing decision, shown before anything runs.
struct PlanCard: View {
    @Environment(AppModel.self) private var model
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(plan.agent.color)
                AgentBadge(agent: plan.agent)
                Text(plan.cwd.isEmpty ? "Choose a folder" : (plan.cwd as NSString).lastPathComponent)
                    .fontWeight(.semibold)
                Text("·").foregroundStyle(.tertiary)
                Text(plan.session.map { "continues “\($0.title.firstLine(50))”" } ?? "new session")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !plan.reason.isEmpty {
                Text(plan.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Menu(plan.cwd.isEmpty ? "Choose Project" : "Change") {
                    Section("Agent") {
                        ForEach(model.agents) { agent in
                            Button(agent.name) { model.plan?.agent = agent; if plan.session?.agent != agent { model.plan?.session = nil } }
                        }
                    }
                    Section("Project") {
                        ForEach(model.projects.prefix(12)) { p in
                            Button(p.path.abbreviatingHome) { model.plan?.cwd = p.path; model.plan?.session = nil }
                        }
                        Button("Choose Folder…") {
                            if let path = chooseFolder() { model.plan?.cwd = path; model.plan?.session = nil }
                        }
                    }
                    if plan.session != nil {
                        Button("Start a new session instead") { model.plan?.session = nil }
                    }
                }
                .fixedSize()
                Button("Cancel") { model.plan = nil }
                Spacer()
                Button("Start") { model.startPlan() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.cwd.isEmpty)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AnswerCard: View {
    @Environment(AppModel.self) private var model
    let answer: Answer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownText(text: answer.text)
            ForEach(answer.sessions) { s in
                Button { model.selection = s.id } label: {
                    HStack {
                        StatusIcon(status: model.status(s)).frame(width: 16)
                        Text(s.title).lineLimit(1)
                        Spacer()
                        AgentBadge(agent: s.agent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A session waiting on you, with the AI's suggested reply one click away.
struct NeedsYouRow: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let t = model.triage[session.id]
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(status: model.status(session)).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Button { model.selection = session.id } label: {
                    Text(session.title).fontWeight(.medium).lineLimit(1)
                }
                .buttonStyle(.plain)
                if let summary = t?.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let next = t?.next, !next.isEmpty, !model.isRunning(session.id), model.asks[session.id]?.isEmpty != false {
                Button("Reply: \(next)") {
                    model.send(next, to: session)
                    model.selection = session.id
                }
                .help("Send this reply to \(session.agent.name)")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Session

struct SessionView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let running = model.isRunning(session.id)
        let t = model.triage[session.id]
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    AgentBadge(agent: session.agent)
                    Text(session.cwd.abbreviatingHome)
                        .truncationMode(.head)
                    if let branch = session.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let t, !running, !t.summary.isEmpty {
                    HStack(spacing: 8) {
                        StatusIcon(status: model.status(session)).frame(width: 14)
                        Text(t.summary).font(.callout)
                        if !t.next.isEmpty, model.asks[session.id]?.isEmpty != false {
                            Button("Reply: \(t.next)") { model.send(t.next, to: session) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            Transcript(items: model.transcripts[session.id], running: running)
            if let ask = model.asks[session.id]?.first {
                AskCard(ask: ask) { allow, answers in model.respond(ask, in: session.id, allow: allow, answers: answers) }
                    .id(ask.id)  // fresh answers for each new ask
            }
            Composer(agent: session.agent, running: running, placeholder: "Reply to \(session.agent.name)…",
                     onSend: { model.send($0, to: session) }, onStop: { model.stop(session.id) })
        }
        .toolbar {
            ToolbarItemGroup {
                SessionActions(session: session, menu: false)
            }
        }
        .task(id: session.id) { await model.load(session) }
    }
}

struct SessionActions: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let menu: Bool  // context menu gets the extras

    var body: some View {
        let running = model.isRunning(session.id)
        let app = model.appName(session)
        let reviewer = session.agent.other
        Button { model.review(session) } label: {
            Label("Review with \(reviewer.name)", systemImage: "checkmark.bubble")
        }
        .help("Ask \(reviewer.name) to review these changes, read-only")
        .disabled(!model.agents.contains(reviewer) || session.id.hasPrefix("pending-"))
        Button { if let url = model.appURL(session) { NSWorkspace.shared.open(url) } } label: {
            Label("Open in \(app ?? "\(session.agent.name) app")", systemImage: "arrow.up.forward.app")
        }
        .help(app.map { "Open in \($0)" } ?? "Only sessions started in the \(session.agent.name) app can be opened there")
        .disabled(app == nil || running)
        Button { model.resumeInTerminal(session) } label: {
            Label("Resume in Terminal", systemImage: "terminal")
        }
        .help("Resume in Terminal")
        .disabled(running)
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) } label: {
            Label("Show Folder", systemImage: "folder")
        }
        .help(session.cwd.abbreviatingHome)
        if menu {
            Divider()
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
        }
    }
}

func chooseFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.url?.path : nil
}
