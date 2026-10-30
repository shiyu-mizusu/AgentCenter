import XCTest
@testable import AgentCenter

/// Runs a real one-line task through each installed CLI, approving any permission prompt.
/// Costs a few tokens and leaves one session per agent: LIVE=1 swift test --filter LiveTests
@MainActor final class LiveTests: XCTestCase {
    func testClaudeAndCodexRuns() async throws {
        guard ProcessInfo.processInfo.environment["LIVE"] != nil else { throw XCTSkip("Set LIVE=1 to run") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentcenter-live-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel()
        await model.refresh()

        for agent in Agent.allCases where model.problems[agent] == nil {
            let file = dir.appendingPathComponent("\(agent.rawValue).txt")
            model.start("Use a shell command to create an empty file named \(file.lastPathComponent) in the current directory, then reply with exactly: done",
                        agent: agent, cwd: dir.path)
            let deadline = Date.now.addingTimeInterval(240)
            while let key = model.selection, model.isRunning(key), Date.now < deadline {
                if let approval = model.approvals[key]?.first { model.answer(approval, in: key, allow: true) }
                try await Task.sleep(for: .milliseconds(200))
            }
            let key = try XCTUnwrap(model.selection)
            let items = model.transcripts[key] ?? []
            print("[\(agent.name)] session \(key):", items.map { "\($0.kind): \($0.text.firstLine(80))" })
            XCTAssertFalse(key.hasPrefix("pending-"), "\(agent.name) never reported a session id")
            XCTAssertTrue(items.contains { $0.kind == .assistant && $0.text.lowercased().contains("done") }, "\(agent.name) didn't answer")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(agent.name) didn't create the file")
        }
    }

    func testStop() async throws {
        guard ProcessInfo.processInfo.environment["LIVE"] != nil else { throw XCTSkip("Set LIVE=1 to run") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentcenter-live-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel()
        await model.refresh()

        for agent in Agent.allCases where model.problems[agent] == nil {
            model.start("Run the shell command `sleep 60`, then reply with exactly: finished", agent: agent, cwd: dir.path)
            var stoppedAt: Date?
            let deadline = Date.now.addingTimeInterval(120)
            while let key = model.selection, model.isRunning(key), Date.now < deadline {
                if let approval = model.approvals[key]?.first { model.answer(approval, in: key, allow: true) }
                let toolStarted = model.transcripts[key]?.contains { $0.kind == .tool } == true
                if stoppedAt == nil, toolStarted { model.stop(key); stoppedAt = .now }
                try await Task.sleep(for: .milliseconds(200))
            }
            let key = try XCTUnwrap(model.selection)
            let items = model.transcripts[key] ?? []
            print("[\(agent.name)] stop:", items.map { "\($0.kind): \($0.text.firstLine(60))" })
            let stopped = try XCTUnwrap(stoppedAt, "\(agent.name) never started the command")
            XCTAssertLessThan(Date.now.timeIntervalSince(stopped), 15, "\(agent.name) kept running after Stop")
            XCTAssertFalse(items.contains { $0.kind == .assistant && $0.text.contains("finished") }, "\(agent.name) wasn't interrupted")
        }
    }
}
