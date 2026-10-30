import SwiftUI

@main
struct AgentCenterApp: App {
    @State private var model = AppModel()

    init() {
        signal(SIGPIPE, SIG_IGN)  // a CLI exiting mid-write must not take the app down
        NSApplication.shared.setActivationPolicy(.regular)  // needed when run unbundled via `swift run`
    }

    var body: some Scene {
        Window("AgentCenter", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") { model.selection = nil }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("codexPath") private var codexPath = ""
    @AppStorage("aiTriage") private var aiTriage = true

    var body: some View {
        Form {
            Section {
                Toggle("Summarize recent sessions with AI", isOn: $aiTriage)
            } header: {
                Text("AI")
            } footer: {
                Text("Sorts sessions into Needs you / Running / Recent and writes a one-line status for each. It sends the last request and reply of recently active sessions to Claude Haiku (or Codex) through your own login.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Claude Code", text: $claudePath, prompt: Text(Claude.binary ?? "Not found"))
                TextField("Codex", text: $codexPath, prompt: Text(Codex.binary ?? "Not found"))
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("Leave empty to auto-detect from your login shell's PATH. Codex is also found inside the ChatGPT or Codex app, Claude Code inside the Claude app.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: codexPath) { model.codex.reset() }
    }
}
