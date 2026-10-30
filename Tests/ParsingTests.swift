import XCTest
@testable import AgentCenter

final class ParsingTests: XCTestCase {
    func testClaudeSessionFile() throws {
        let lines = [
            #"{"type":"custom-title","customTitle":"Old name","sessionId":"s1"}"#,
            #"{"parentUuid":null,"isSidechain":false,"type":"user","isMeta":true,"cwd":"/tmp/demo","entrypoint":"claude-desktop","gitBranch":"main","uuid":"u0","message":{"role":"user","content":"Caveat: ignore"}}"#,
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
        XCTAssertTrue(session.fromDesktop)

        let items = Claude.transcript(url)
        XCTAssertEqual(items.map(\.kind), [.user, .tool, .assistant, .user])
        XCTAssertEqual(items[0].text, "Fix the login bug")
        XCTAssertEqual(items[1].text, "$ npm test")
        XCTAssertEqual(items[1].detail, "1 failing")
        XCTAssertTrue(items[1].failed)
        XCTAssertEqual(items[3].text, "/review src")
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
