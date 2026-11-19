import Foundation
import XCTest
@testable import AgentHud

final class DiscoveryWaitingTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func append(_ url: URL, type: String, payload: [String: Any]) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try JSONSerialization.data(withJSONObject: ["timestamp": formatter.string(from: Date()), "type": type, "payload": payload])
        data.append(0x0A)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
    }

    func testCodexQuestionAndApprovalLifecycle() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("rollout-test.jsonl")
        try Data().write(to: path)
        try append(path, type: "session_meta", payload: ["id": "test", "cwd": home.path])
        var provider = CodexProvider(home: home.path)
        func state() async throws -> AgentState? { try await provider.discover().first?.state }
        try append(path, type: "response_item", payload: ["type": "function_call", "name": "exec_command", "call_id": "ordinary", "arguments": "{}"])
        var actual = try await state()
        XCTAssertEqual(actual, .working, "Ordinary function calls are not questions")
        try append(path, type: "response_item", payload: ["type": "function_call", "name": "request_user_input", "call_id": "question"])
        actual = try await state()
        XCTAssertEqual(actual, .waitingForInput)
        try append(path, type: "response_item", payload: ["type": "function_call_output", "call_id": "unrelated", "output": "done"])
        actual = try await state()
        XCTAssertEqual(actual, .waitingForInput, "Unrelated output does not answer a question")
        try append(path, type: "response_item", payload: ["type": "function_call_output", "call_id": "question", "output": "answer"])
        actual = try await state()
        XCTAssertEqual(actual, .working)
        try append(path, type: "response_item", payload: ["type": "function_call", "name": "request_user_input_async", "call_id": "async"])
        try append(path, type: "response_item", payload: ["type": "function_call_output", "call_id": "async", "output": "accepted"])
        try append(path, type: "event_msg", payload: ["type": "task_complete"])
        actual = try await state()
        XCTAssertEqual(actual, .completed)
        let pending = try await provider.discover().first
        XCTAssertEqual(pending?.needsInput, true)
        XCTAssertEqual(pending?.displayState, .waitingForInput)
        try append(path, type: "event_msg", payload: ["type": "user_message"])
        let approvals: [[String: Any]] = [
            ["type": "function_call", "name": "exec_command", "call_id": "approval", "arguments": #"{"sandbox_permissions":"require_escalated"}"#],
            ["type": "custom_tool_call", "name": "exec", "call_id": "approval", "input": "await tools.exec_command({sandbox_permissions: 'require_escalated'});"],
            ["type": "custom_tool_call", "name": "functions.exec", "call_id": "approval", "input": "await tools.exec_command({sandbox_permissions: 'require_escalated'});"]
        ]
        for approval in approvals {
            try append(path, type: "response_item", payload: approval)
            try append(path, type: "response_item", payload: ["type": "reasoning"])
            actual = try await state()
            XCTAssertEqual(actual, .thinking)
            provider = CodexProvider(home: home.path)
            actual = try await state()
            XCTAssertEqual(actual, .thinking, "Escalation text is not proof of a pending approval")
            try append(path, type: "response_item", payload: ["type": "custom_tool_call_output", "call_id": "approval", "output": [["type": "input_text", "text": "Script running with cell ID 42"]]])
            actual = try await state()
            XCTAssertEqual(actual, .working)
            try append(path, type: "response_item", payload: ["type": "function_call", "name": "wait", "call_id": "wait", "arguments": #"{"cell_id":"42"}"#])
            try append(path, type: "response_item", payload: ["type": "function_call_output", "call_id": "wait", "output": "Script running with cell ID 42"])
            actual = try await state()
            XCTAssertEqual(actual, .working)
            try append(path, type: "response_item", payload: ["type": "function_call", "name": "functions.wait", "call_id": "final", "arguments": #"{"cell_id":"42"}"#])
            provider = CodexProvider(home: home.path)
            actual = try await state()
            XCTAssertEqual(actual, .working)
            try append(path, type: "response_item", payload: ["type": "function_call_output", "call_id": "final", "output": "Script completed"])
            actual = try await state()
            XCTAssertEqual(actual, .working)
        }
        try append(path, type: "response_item", payload: approvals[0])
        try append(path, type: "event_msg", payload: ["type": "turn_aborted"])
        actual = try await state()
        XCTAssertEqual(actual, .stopped)
    }

    func testClaudeQuestionTakesPriorityOverRateLimit() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".claude/sessions")
        let project = home.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let metadata: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "sessionId": id, "status": "busy", "cwd": home.path]
        try JSONSerialization.data(withJSONObject: metadata).write(to: sessions.appendingPathComponent("test.json"))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let question: [String: Any] = ["type": "assistant", "sessionId": id, "message": ["content": [["type": "tool_use", "name": "AskUserQuestion", "id": "ask"]]]]
        let limit: [String: Any] = ["type": "assistant", "sessionId": id, "timestamp": formatter.string(from: Date()), "isApiErrorMessage": true, "error": "rate_limit", "message": ["content": [["type": "text", "text": "try again in 1 hours"]]]]
        var transcript = Data()
        for item in [question, limit] {
            transcript.append(try JSONSerialization.data(withJSONObject: item))
            transcript.append(0x0A)
        }
        try transcript.write(to: project.appendingPathComponent(id + ".jsonl"))
        let result = try await ClaudeCodeProvider(home: home.path).discover()
        XCTAssertEqual(result.first?.state, .waitingForInput)
        XCTAssertNotNil(result.first?.rateLimitResetAt)
    }
    func testClaudeOldEndTurnDoesNotCompleteANewUserTurn() async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".claude/sessions")
        let project = home.appendingPathComponent(".claude/projects/fixture")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
            "sessionId": id, "status": "idle", "cwd": home.path]).write(to: sessions.appendingPathComponent("fixture.json"))
        let transcript = project.appendingPathComponent(id + ".jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        func line(_ type: String, message: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "sessionId": id,
                "timestamp": timestamp, "message": message])
            data.append(10); return data
        }
        var data = try line("assistant", message: ["stop_reason": "end_turn"])
        try data.write(to: transcript)
        let provider = ClaudeCodeProvider(home: home.path)
        let completed = try await provider.discover().first
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertNotNil(completed?.completionRevision)
        data.append(try line("user", message: ["content": "new turn"]))
        try data.write(to: transcript)
        let next = try await provider.discover().first
        XCTAssertNotEqual(next?.state, .completed)
        XCTAssertNil(next?.completionRevision)
    }

    func testOldIncompleteClaudeTranscriptDoesNotKeepSpinnerRunning() async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".claude/sessions")
        let project = home.appendingPathComponent(".claude/projects/fixture")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
            "sessionId": id, "status": "idle", "cwd": home.path]).write(to: sessions.appendingPathComponent("fixture.json"))
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
        var data = try JSONSerialization.data(withJSONObject: ["type": "assistant", "sessionId": id,
            "timestamp": old, "message": ["content": [["type": "text", "text": "fixture"]]]])
        data.append(10)
        try data.write(to: project.appendingPathComponent(id + ".jsonl"))
        let result = try await ClaudeCodeProvider(home: home.path).discover().first
        XCTAssertEqual(result?.state, .unknown)
        XCTAssertNil(result?.completionRevision)
    }

}

extension DiscoveryWaitingTests {
    func testPollRecoversCodexFinalWithoutStopHookAndResetsOnNewTurn() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("rollout.jsonl")
        try Data().write(to: path)
        try append(path, type: "session_meta", payload: ["id": UUID().uuidString])
        try append(path, type: "event_msg", payload: ["type": "task_started", "turn_id": "first"])
        let provider = CodexProvider(home: home.path)
        try append(path, type: "response_item", payload: ["type": "message", "role": "assistant", "phase": "commentary"])
        let before = try await provider.discover().first
        XCTAssertEqual(before?.state, .working)
        try append(path, type: "response_item", payload: ["type": "message", "role": "assistant", "phase": "final_answer"])
        let after = try await provider.discover().first
        XCTAssertEqual(after?.state, .completed)
        XCTAssertEqual(after?.completionRevision, "turn:first")
        let cold = try await CodexProvider(home: home.path).discover().first
        XCTAssertEqual(cold?.completionRevision, "turn:first")
        try append(path, type: "event_msg", payload: ["type": "task_started", "turn_id": "second"])
        let next = try await provider.discover().first
        XCTAssertEqual(next?.state, .working)
        XCTAssertNil(next?.completionRevision)
        let unindexed = root.appendingPathComponent("rollout-no-context.jsonl")
        try Data().write(to: unindexed)
        let id = UUID().uuidString.lowercased()
        try append(unindexed, type: "session_meta", payload: ["id": id])
        try append(unindexed, type: "response_item", payload: ["type": "message", "role": "assistant", "phase": "final_answer"])
        let recovered = try await provider.discover().first { $0.id == "codex:" + id }!
        let registry = AgentSessionRegistry(storageURL: nil)
        registry.replace([recovered])
        registry.acknowledgeCompletion(recovered.id, revision: recovered.completionRevision)
        try append(unindexed, type: "event_msg", payload: ["type": "task_complete", "turn_id": "original-turn"])
        registry.replace(try await provider.discover())
        XCTAssertFalse(registry.findSession(recovered.id)!.hasUnreadCompletion)
    }
}

extension DiscoveryWaitingTests {
    func testCodexDesktopRepliesResolveOnlyAnsweredAsyncQuestions() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("rollout-test.jsonl")
        try Data().write(to: path)
        try append(path, type: "session_meta", payload: ["id":"fixture", "cwd":home.path])
        let provider = CodexProvider(home: home.path)
        func ask(_ id: String, count: Int) throws {
            let args = try JSONSerialization.data(withJSONObject: ["questions": Array(repeating: ["title": "Test?"], count: count)])
            try append(path, type: "response_item", payload: ["type":"function_call", "name":"request_user_input_async",
                "arguments":String(decoding: args, as: UTF8.self), "call_id":id])
        }
        func answer(_ id: String, _ index: Int, role: String = "user") throws {
            let key = try JSONSerialization.data(withJSONObject: ["request_user_input_async", id, index] as [Any])
            let body = try JSONSerialization.data(withJSONObject: [["questionItemId":String(decoding: key, as: UTF8.self), "answer":"yes"]])
            let text = "<send_user_message_question_reply>\n" + String(decoding: body, as: UTF8.self) + "\n</send_user_message_question_reply>\n"
            try append(path, type: "response_item", payload: ["type":"message", "role":role, "content":[["type":"input_text","text":text]]])
        }
        func check(_ expected: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let row = try await provider.discover().first
            XCTAssertEqual(row?.needsInput, expected, file: file, line: line)
        }
        try ask("A", count: 2)
        try ask("B", count: 1)
        try append(path, type: "event_msg", payload: ["type": "task_complete"])
        try await check(true)
        try answer("B", 0)
        try append(path, type: "event_msg", payload: ["type":"user_message", "message":"Unrelated follow-up"])
        try await check(true)
        try answer("A", 1)
        try await check(true)
        try answer("A", 1); try answer("unrelated", 0); try answer("A", 0, role: "assistant")
        try await check(true)
        try answer("A", 0)
        try append(path, type: "response_item", payload: ["type":"function_call_output", "output":String(repeating: "x", count: 275000)])
        try await check(false)
        let restarted = try await CodexProvider(home: home.path).discover().first
        XCTAssertEqual(restarted?.needsInput, false)
    }
}
