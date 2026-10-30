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
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") { model.selection = AppModel.newTaskID }
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

    var body: some View {
        Form {
            Section {
                TextField("Claude Code", text: $claudePath, prompt: Text(Claude.binary ?? "Not found"))
                TextField("Codex", text: $codexPath, prompt: Text(Codex.binary ?? "Not found"))
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("Leave empty to auto-detect from your login shell's PATH. Codex is also found inside the ChatGPT or Codex app.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: codexPath) { model.codex.reset() }
    }
}
