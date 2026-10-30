import SwiftUI
import XCTest
@testable import AgentCenter

/// Renders the UI offscreen to PNGs (README screenshots, visual checks). Glass/vibrancy (the sidebar)
/// doesn't survive offscreen capture, so docs/screenshot.png is the list + detail area of demo.png.
/// Run with: SNAPSHOT_DIR=/tmp/shots swift test --filter SnapshotTests
@MainActor final class SnapshotTests: XCTestCase {
    func testDemo() async throws {
        try requireOutput()
        let model = AppModel()
        model.loading = true  // keep refresh() from replacing the demo data
        let now = Date.now
        model.sessions = [
            Session(id: "s1", agent: .claude, title: "Add dark mode to the settings screen", cwd: "/Users/dev/acme-web", updated: now.addingTimeInterval(-120)),
            Session(id: "s2", agent: .codex, title: "Fix flaky checkout test", cwd: "/Users/dev/acme-web", updated: now.addingTimeInterval(-3_600)),
            Session(id: "s3", agent: .codex, title: "Migrate API client to async/await", cwd: "/Users/dev/acme-ios", updated: now.addingTimeInterval(-7_200)),
            Session(id: "s4", agent: .claude, title: "Write release notes for v2.4", cwd: "/Users/dev/acme-ios", updated: now.addingTimeInterval(-86_400)),
            Session(id: "s5", agent: .claude, title: "Profile slow dashboard queries", cwd: "/Users/dev/data-pipeline", updated: now.addingTimeInterval(-172_800)),
            Session(id: "s6", agent: .codex, title: "Bump dependencies and fix warnings", cwd: "/Users/dev/data-pipeline", updated: now.addingTimeInterval(-259_200)),
        ]
        model.transcripts["s1"] = [
            Item(id: "1", kind: .user, text: "Add a dark mode toggle to the settings screen and remember the choice."),
            Item(id: "2", kind: .assistant, text: "I'll look at how settings are stored first."),
            Item(id: "3", kind: .tool, text: "Read ~/acme-web/src/settings/SettingsPage.tsx", icon: "doc.text"),
            Item(id: "4", kind: .tool, text: "Edit ~/acme-web/src/settings/SettingsPage.tsx", icon: "pencil"),
            Item(id: "5", kind: .tool, text: "$ npm test -- settings", detail: "PASS  src/settings/SettingsPage.test.tsx", icon: "terminal"),
            Item(id: "6", kind: .assistant, text: "Done. **Dark mode** now lives under *Settings → Appearance*:\n\n- The toggle writes `theme` to local storage\n- The app reads it on launch, before first paint\n\n```ts\nconst theme = localStorage.getItem(\"theme\") ?? \"system\"\n```\n\nTests pass."),
        ]
        model.selection = "s1"
        model.approvals["s1"] = [Approval(id: "a", title: "$ git commit -am \"Add dark mode\"", detail: "Commit the change", respond: { _ in })]
        try await snapshot(model, "demo")

        model.approvals["s1"] = nil
        model.selection = AppModel.newTaskID
        try await snapshot(model, "demo-new-task")
    }

    /// Your real sessions — for eyeballing locally, never for the README.
    func testRealData() async throws {
        try requireOutput()
        let model = AppModel()
        await model.refresh()
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
        let host = NSHostingView(rootView: ContentView().environment(model))
        host.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))  // render without showing anything on screen
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(2))
        let frame = try XCTUnwrap(host.superview)  // includes the title bar and toolbar
        func flatten(_ view: NSView) {  // behind-window vibrancy doesn't survive an offscreen capture
            if let effect = view as? NSVisualEffectView {
                effect.state = .inactive
                effect.blendingMode = .withinWindow
            }
            view.subviews.forEach(flatten)
        }
        flatten(frame)
        frame.display()
        let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}
