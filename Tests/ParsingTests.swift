import XCTest
@testable import AgentCenter

final class ParsingTests: XCTestCase {
    func testClaudeSessionFile() throws {
        let lines = [
            #"{"type":"custom-title","customTitle":"Old name","sessionId":"s1"}"#,
            #"{"parentUuid":null,"isSidechain":false,"type":"user","isMeta":true,"cwd":"/tmp/demo","gitBranch":"main","uuid":"u0","message":{"role":"user","content":"Caveat: ignore"}}"#,
            #"{"parentUuid":"u0","isSidechain":false,"type":"user","cwd":"/tmp/demo","uuid":"u1","message":{"role":"user","content":"<system-reminder>noise</system-reminder>Fix the login bug"}}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]},"type":"assistant","uuid":"a1"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]},"type":"assistant","uuid":"a2"}"#,
            #"{"parentUuid":"a2","isSidechain":false,"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"1 failing","is_error":true}]}}"#,
            #"{"parentUuid":"u2","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]},"type":"assistant","uuid":"a3"}"#,
            #"{"parentUuid":"u2","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Fixed it."}]},"type":"assistant","uuid":"a4"}"#,
            #"{"parentUuid":"a4","isSidechain":false,"type":"user","uuid":"u3","message":{"role":"user","content":"<command-name>/review</command-name>\n<command-message>review</command-message>\n<command-args>src</command-args>"}}"#,
            #"{"type":"custom-title","customTitle":"Login bug","sessionId":"s1"}"#,
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try XCTUnwrap(Claude.summarize(url, modified: .now))
        XCTAssertEqual(session.title, "Login bug")  // the latest rename wins
        XCTAssertEqual(session.cwd, "/tmp/demo")
        XCTAssertEqual(session.branch, "main")

        let items = Claude.transcript(url)
        XCTAssertEqual(items.map(\.kind), [.user, .tool, .assistant, .user])
        XCTAssertEqual(items[0].text, "Fix the login bug")
        XCTAssertEqual(items[1].text, "$ npm test")
        XCTAssertEqual(items[1].detail, "1 failing")
        XCTAssertTrue(items[1].failed)
        XCTAssertEqual(items[3].text, "/review src")

        // The last request (the /review command) came after the agent's last words: no reply yet.
        let last = try XCTUnwrap(Claude.lastExchange(url))
        XCTAssertEqual(last.prompt, "/review src")
        XCTAssertEqual(last.reply, "(no reply to this yet)")

        // A run that kept calling tools after its last words, with the request scrolled out of the tail.
        let busy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try [lines[3], lines[7], lines[4]].joined(separator: "\n").write(to: busy, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: busy) }
        let working = try XCTUnwrap(Claude.lastExchange(busy))
        XCTAssertEqual(working.prompt, "(earlier in the session)")
        XCTAssertEqual(working.reply, "Fixed it.\n\n(After this message it kept calling tools.)")
    }

    func testRouteDecisionOnlyActsOnKnownTargets() {
        let projects = [Project(path: "/dev/web"), Project(path: "/dev/api")]
        let api = Session(id: "t1", agent: .codex, title: "Fix flaky test", cwd: "/dev/api", updated: .now)
        func decide(_ raw: [String: Any], agents: [Agent] = [.claude, .codex]) -> Decision {
            Brain.decision(raw, request: "do it", projects: projects, sessions: [api], agents: agents)
        }

        // Continuing a known session uses that session's agent and folder, whatever agent the model named.
        guard case .run(let p1) = decide(["action": "continue", "session": "t1", "agent": "claude", "project": 0]) else { return XCTFail() }
        XCTAssertEqual(p1.session?.id, "t1")
        XCTAssertEqual(p1.agent, .codex)
        XCTAssertEqual(p1.cwd, "/dev/api")

        // An unknown session falls back to a new session in the named project.
        guard case .run(let p2) = decide(["action": "continue", "session": "nope", "agent": "claude", "project": 0]) else { return XCTFail() }
        XCTAssertNil(p2.session)
        XCTAssertEqual(p2.cwd, "/dev/web")

        // A project index out of range never becomes a path: the request waits for the person to pick a folder.
        guard case .run(let unknown) = decide(["action": "new", "agent": "claude", "project": 7, "answer": ""]) else { return XCTFail() }
        XCTAssertEqual(unknown.cwd, "")
        XCTAssertEqual(unknown.request, "do it")

        // An agent that isn't installed is swapped for one that is.
        guard case .run(let p3) = decide(["action": "new", "agent": "codex", "project": 1], agents: [.claude]) else { return XCTFail() }
        XCTAssertEqual(p3.agent, .claude)
    }

    func testCodexItems() {
        XCTAssertEqual(Codex.unwrap("/bin/zsh -lc 'ls -la'"), "ls -la")
        XCTAssertEqual(Codex.unwrap("bash -c \"echo hi\""), "echo hi")
        XCTAssertEqual(Codex.unwrap("git status"), "git status")

        let run = Codex.item(["type": "commandExecution", "id": "c1", "command": "/bin/zsh -lc 'swift test'",
                              "aggregatedOutput": "boom", "exitCode": 1])
        XCTAssertEqual(run?.text, "$ swift test")
        XCTAssertEqual(run?.failed, true)
        XCTAssertEqual(Codex.item(["type": "agentMessage", "id": "m1", "text": " Done. "])?.text, "Done.")
        XCTAssertEqual(Codex.item(["type": "userMessage", "id": "u1",
                                   "content": [["type": "text", "text": "hi"], ["type": "localImage", "path": "/x.png"]]])?.text, "hi\n[image]")
        XCTAssertNil(Codex.item(["type": "reasoning", "id": "r1"]))
    }

    func testMarkdownBlocks() {
        let blocks = MarkdownText.blocks("Intro\n```swift\nlet x = 1\n```\nOutro")
        XCTAssertEqual(blocks.map(\.code), [false, true, false])
        XCTAssertEqual(blocks[1].text, "let x = 1")
    }
}
