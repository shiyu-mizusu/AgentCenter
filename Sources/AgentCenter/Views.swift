import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 340)
        } content: {
            SessionList()
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 480)
        } detail: {
            Detail()
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search sessions")
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refresh()
                if let s = model.selected { await model.load(s) }
            }
        }
    }
}

// MARK: - Columns

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.scope) {
            Label("All Sessions", systemImage: "tray.full")
                .tag(Scope.all)
            Section("Projects") {
                ForEach(model.projects) { p in
                    Label(p.name, systemImage: "folder")
                        .badge(p.count)
                        .help(p.path.abbreviatingHome)
                        .tag(Scope.project(p.path))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Agent.allCases) { agent in
                    if let problem = model.problems[agent] {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.multicolor)
                            .lineLimit(3)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, model.problems.isEmpty ? 0 : 10)
        }
        .toolbar {
            ToolbarItem {
                Button { model.selection = AppModel.newTaskID } label: {
                    Label("New Task", systemImage: "square.and.pencil")
                }
                .help("New task (⌘N)")
            }
        }
    }
}

struct SessionList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(model.visible, selection: $model.selection) { session in
            SessionRow(session: session, showProject: model.scope == .all || model.scope == nil)
                .contextMenu { SessionActions(session: session, includeCopy: true) }
        }
        .overlay {
            if model.visible.isEmpty {
                if model.loading {
                    ProgressView()
                } else {
                    ContentUnavailableView(model.search.isEmpty ? "No Sessions" : "No Results",
                                           systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(model.visible.count) sessions")
        .toolbar {
            ToolbarItem {
                Picker("Agent", selection: $model.agentFilter) {
                    Text("All").tag(Agent?.none)
                    ForEach(Agent.allCases) { Text($0.name).tag(Agent?.some($0)) }
                }
                .pickerStyle(.segmented)
                .help("Show sessions from")
            }
            ToolbarItem {
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
                .disabled(model.loading)
            }
        }
    }

    private var title: String {
        if case .project(let path)? = model.scope { return (path as NSString).lastPathComponent }
        return "All Sessions"
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let showProject: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .lineLimit(2)
            HStack(spacing: 6) {
                AgentBadge(agent: session.agent)
                if showProject {
                    Text((session.project as NSString).lastPathComponent)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if model.isRunning(session.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(session.updated.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
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

struct Detail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selection == AppModel.newTaskID {
            NewTask()
        } else if let session = model.selected {
            SessionView(session: session)
                .id(session.id)
        } else {
            ContentUnavailableView {
                Label("No Session Selected", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Pick a Claude Code or Codex session, or start a new task.")
            } actions: {
                Button("New Task") { model.selection = AppModel.newTaskID }
                    .keyboardShortcut("n")
            }
        }
    }
}

// MARK: - Session

struct SessionView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let running = model.isRunning(session.id)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            Transcript(items: model.transcripts[session.id], running: running)
            if let approval = model.approvals[session.id]?.first {
                ApprovalCard(approval: approval) { model.answer(approval, in: session.id, allow: $0) }
            }
            Composer(agent: session.agent, running: running, placeholder: "Reply to \(session.agent.name)…",
                     onSend: { model.send($0, to: session) }, onStop: { model.stop(session.id) })
        }
        .toolbar {
            ToolbarItemGroup {
                SessionActions(session: session, includeCopy: false)
            }
        }
        .task(id: session.id) { await model.load(session) }
    }
}

struct SessionActions: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let includeCopy: Bool

    var body: some View {
        let app = model.appName(session)
        Button { if let url = model.appURL(session) { NSWorkspace.shared.open(url) } } label: {
            Label("Open in \(app ?? "\(session.agent.name) app")", systemImage: "arrow.up.forward.app")
        }
        .help(app.map { "Open in \($0)" } ?? "Only sessions started in the \(session.agent.name) app can be opened there")
        .disabled(app == nil)
        Button { model.resumeInTerminal(session) } label: {
            Label("Resume in Terminal", systemImage: "terminal")
        }
        .help("Resume in Terminal")
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) } label: {
            Label("Show Folder", systemImage: "folder")
        }
        .help(session.cwd.abbreviatingHome)
        if includeCopy {
            Divider()
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
        }
    }
}

// MARK: - New task

struct NewTask: View {
    @Environment(AppModel.self) private var model
    @AppStorage("newTaskAgent") private var agent: Agent = .claude
    @AppStorage("newTaskFolder") private var folder = ""

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("What should we work on?")
                .font(.largeTitle.weight(.semibold))
            HStack(spacing: 12) {
                Picker("Agent", selection: $agent) {
                    ForEach(Agent.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Menu {
                    ForEach(model.projects.prefix(15)) { p in
                        Button(p.path.abbreviatingHome) { folder = p.path }
                    }
                    Divider()
                    Button("Choose Folder…", action: chooseFolder)
                } label: {
                    Label(folder.isEmpty ? "Choose Folder" : folder.abbreviatingHome, systemImage: "folder")
                }
                .fixedSize()
            }
            Composer(agent: agent, placeholder: "Describe a task for \(agent.name)…") { prompt in
                model.start(prompt, agent: agent, cwd: folder)
            }
            .id(agent)
            .disabled(folder.isEmpty)
            Spacer()
            Spacer()
        }
        .padding()
        .onAppear {
            if folder.isEmpty, let recent = model.projects.first { folder = recent.path }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
