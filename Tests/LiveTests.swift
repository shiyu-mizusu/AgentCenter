import XCTest
@testable import AgentCenter

/// Real runs through each installed CLI (approving any prompt), and real AI decisions.
/// Costs a few tokens and leaves a session per agent: LIVE=1 swift test --filter LiveTests
@MainActor final class LiveTests: XCTestCase {
    private func requireLive() throws {
        if ProcessInfo.processInfo.environment["LIVE"] == nil { throw XCTSkip("Set LIVE=1 to run") }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentcenter-live-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Waits for the selected run to finish, answering whatever it asks.
    private func finish(_ model: AppModel, stopWhen: ((String) -> Bool)? = nil) async throws -> Date? {
        var stoppedAt: Date?
        let deadline = Date.now.addingTimeInterval(240)
        while let key = model.selection, model.isRunning(key), Date.now < deadline {
            if let ask = model.asks[key]?.first {
                model.respond(ask, in: key, allow: true, answers: Dictionary(uniqueKeysWithValues: ask.questions.map { ($0.id, $0.options.first ?? "yes") }))
            }
            if stoppedAt == nil, stopWhen?(key) == true { model.stop(key); stoppedAt = .now }
            try await Task.sleep(for: .milliseconds(200))
        }
        return stoppedAt
    }

    func testClaudeAndCodexRuns() async throws {
        try requireLive()
        let dir = try tempDir()
        let model = AppModel()
        await model.refresh()

        for agent in model.agents {
            let file = dir.appendingPathComponent("\(agent.rawValue).txt")
            model.start("Use a shell command to create an empty file named \(file.lastPathComponent) in the current directory, then reply with exactly: done",
                        agent: agent, cwd: dir.path)
            _ = try await finish(model)
            let key = try XCTUnwrap(model.selection)
            let items = model.transcripts[key] ?? []
            print("[\(agent.name)] session \(key):", items.map { "\($0.kind): \($0.text.firstLine(80))" })
            XCTAssertFalse(key.hasPrefix("pending-"), "\(agent.name) never reported a session id")
            XCTAssertTrue(items.contains { $0.kind == .assistant && $0.text.lowercased().contains("done") }, "\(agent.name) didn't answer")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(agent.name) didn't create the file")
        }
    }

    func testStop() async throws {
        try requireLive()
        let dir = try tempDir()
        let model = AppModel()
        await model.refresh()

        for agent in model.agents {
            model.start("Run the shell command `sleep 60`, then reply with exactly: finished", agent: agent, cwd: dir.path)
            let stoppedAt = try await finish(model) { key in model.transcripts[key]?.contains { $0.kind == .tool } == true }
            let key = try XCTUnwrap(model.selection)
            let items = model.transcripts[key] ?? []
            print("[\(agent.name)] stop:", items.map { "\($0.kind): \($0.text.firstLine(60))" })
            let stopped = try XCTUnwrap(stoppedAt, "\(agent.name) never started the command")
            XCTAssertLessThan(Date.now.timeIntervalSince(stopped), 15, "\(agent.name) kept running after Stop")
            XCTAssertFalse(items.contains { $0.kind == .assistant && $0.text.contains("finished") }, "\(agent.name) wasn't interrupted")
        }
    }

    /// The brain routes to the project a request names, answers questions about work, and triages.
    func testBrain() async throws {
        try requireLive()
        let model = AppModel()
        model.loading = true  // keep refresh() away; this test brings its own sessions
        model.problems = [:]
        let now = Date.now
        model.sessions = [
            Session(id: "s-web", agent: .claude, title: "Add dark mode to settings", cwd: "/Users/dev/acme-web", updated: now.addingTimeInterval(-300)),
            Session(id: "s-ios", agent: .codex, title: "Migrate API client to async/await", cwd: "/Users/dev/acme-ios", updated: now.addingTimeInterval(-7200)),
        ]
        model.triage["s-ios"] = Triage(state: .needsYou, summary: "Asked whether to keep the old completion-handler API",
                                       next: "Keep it, deprecated", updated: now.addingTimeInterval(-7200), at: now)

        await model.route("In the iOS app, add pull-to-refresh to the orders screen")
        let plan = try XCTUnwrap(model.plan, "no plan; answer: \(model.answer?.text ?? "-")")
        print("route ->", plan.agent, plan.cwd, plan.session?.id ?? "new", "|", plan.reason)
        XCTAssertEqual(plan.cwd, "/Users/dev/acme-ios")

        await model.route("What needs my attention?")
        let answer = try XCTUnwrap(model.answer, "expected an answer, got a plan")
        print("answer ->", answer.text, answer.sessions.map(\.id))
        XCTAssertTrue(answer.sessions.contains { $0.id == "s-ios" })

        let verdicts = try await Brain.triage([
            Brain.Case(session: model.sessions[0], prompt: "Add a dark mode toggle", reply: "Should the toggle live under Settings or the profile menu?", failed: false),
            Brain.Case(session: model.sessions[1], prompt: "Migrate the client", reply: "Done. All call sites use async/await now.", failed: false),
        ])
        print("triage ->", verdicts.mapValues { "\($0.state.rawValue): \($0.summary) | \($0.next)" })
        XCTAssertEqual(verdicts["s-web"]?.state, .needsYou)
        XCTAssertEqual(verdicts["s-ios"]?.state, .done)
    }
}
