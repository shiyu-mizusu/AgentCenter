import SwiftUI
import XCTest
@testable import AgentCenter

/// Renders the UI offscreen to PNGs (README screenshots, visual checks).
/// The sidebar's glass doesn't survive an offscreen capture, so the README shots lay the real inbox and
/// detail views side by side on an opaque background instead of inside the split view.
/// Run with: SNAPSHOT_DIR=/tmp/shots swift test --filter SnapshotTests
@MainActor final class SnapshotTests: XCTestCase {
    func testDemo() async throws {
        try requireOutput()
        let model = AppModel()
        model.loading = true  // keep refresh() from replacing the demo data
        model.problems = [:]
        let now = Date.now
        model.sessions = [
            Session(id: "s1", agent: .claude, title: "Add dark mode to the settings screen", cwd: "/Users/dev/acme-web", updated: now.addingTimeInterval(-120)),
            Session(id: "s2", agent: .codex, title: "Fix flaky checkout test", cwd: "/Users/dev/acme-web", updated: now.addingTimeInterval(-1_800)),
            Session(id: "s3", agent: .codex, title: "Migrate API client to async/await", cwd: "/Users/dev/acme-ios", updated: now.addingTimeInterval(-3_600)),
            Session(id: "s7", agent: .claude, title: "Add search to the orders list", cwd: "/Users/dev/acme-ios", updated: now.addingTimeInterval(-200)),
            Session(id: "s4", agent: .claude, title: "Write release notes for v2.4", cwd: "/Users/dev/acme-ios", updated: now.addingTimeInterval(-86_400)),
            Session(id: "s5", agent: .claude, title: "Profile slow dashboard queries", cwd: "/Users/dev/data-pipeline", updated: now.addingTimeInterval(-90_000)),
            Session(id: "s6", agent: .codex, title: "Bump dependencies and fix warnings", cwd: "/Users/dev/data-pipeline", updated: now.addingTimeInterval(-200_000)),
        ]
        func t(_ state: Triage.State, _ summary: String, _ next: String = "") -> Triage {
            Triage(state: state, summary: summary, next: next, updated: now, at: now)
        }
        model.triage = [
            "s1": t(.working, "Toggle added and tested; wants to commit"),
            "s2": t(.needsYou, "Found a race in the payment mock; asks whether to add a retry", "Add the retry, max 3 attempts"),
            "s3": t(.needsYou, "Asks whether to keep the old completion-handler API", "Keep it, marked deprecated"),
            "s7": t(.working, "Wiring the search bar to the orders query"),
            "s4": t(.done, "Release notes drafted in CHANGELOG.md"),
            "s5": t(.failed, "Couldn't connect to the staging database"),
            "s6": t(.done, "Dependencies bumped, 12 warnings fixed"),
        ]
        model.transcripts["s1"] = [
            Item(id: "1", kind: .user, text: "Add a dark mode toggle to the settings screen and remember the choice."),
            Item(id: "2", kind: .assistant, text: "I'll look at how settings are stored first."),
            Item(id: "3", kind: .tool, text: "Read ~/acme-web/src/settings/SettingsPage.tsx", icon: "doc.text"),
            Item(id: "4", kind: .tool, text: "Edit ~/acme-web/src/settings/SettingsPage.tsx", icon: "pencil"),
            Item(id: "5", kind: .tool, text: "$ npm test -- settings", detail: "PASS  src/settings/SettingsPage.test.tsx", icon: "terminal"),
            Item(id: "6", kind: .assistant, text: "Done. **Dark mode** now lives under *Settings → Appearance*:\n\n- The toggle writes `theme` to local storage\n- The app reads it on launch, before first paint\n\n```ts\nconst theme = localStorage.getItem(\"theme\") ?? \"system\"\n```\n\nTests pass."),
        ]
        model.asks["s1"] = [Ask(id: "a", title: "$ git commit -am \"Add dark mode\"", detail: "Commit the change", respond: { _, _ in })]
        model.selection = "s1"
        try await snapshot(model, "demo")

        model.selection = nil
        try await snapshot(model, "demo-home")

        model.draft = "Add pull-to-refresh to the orders screen in the iOS app"
        model.plan = Plan(request: model.draft, agent: .claude, cwd: "/Users/dev/acme-ios", session: nil,
                          reason: "Names the iOS app; Claude worked there last.")
        try await snapshot(model, "demo-plan")
    }

    /// Your real sessions, for eyeballing locally. Never for the README.
    func testRealData() async throws {
        try requireOutput()
        let model = AppModel()
        await model.refresh()
        await model.triageRecent()
        while model.triaging { try await Task.sleep(for: .milliseconds(200)) }  // refresh() may have started its own pass
        model.selection = model.sessions.first?.id
        if let s = model.selected { await model.load(s) }
        try await snapshot(model, "real")
    }

    private var outputDir: String? { ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] }

    private func requireOutput() throws {
        if outputDir == nil { throw XCTSkip("Set SNAPSHOT_DIR to render") }
    }

    private func snapshot(_ model: AppModel, _ name: String) async throws {
        let dir = try XCTUnwrap(outputDir)
        let layout = HStack(spacing: 0) {
            Inbox()
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .underPageBackgroundColor))
                .frame(width: 340)
            Divider()
            if let session = model.selected { SessionView(session: session) } else { Home() }
        }
        .environment(model)
        let host = NSHostingView(rootView: layout)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.title = "AgentCenter"
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))  // render without showing anything on screen
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(2))
        let frame = try XCTUnwrap(host.superview)  // includes the title bar
        let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}
