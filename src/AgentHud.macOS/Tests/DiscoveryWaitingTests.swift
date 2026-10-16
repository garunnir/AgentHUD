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
        XCTAssertEqual(actual, .waitingForInput)
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
            XCTAssertEqual(actual, .waitingForApproval)
            provider = CodexProvider(home: home.path)
            actual = try await state()
            XCTAssertEqual(actual, .waitingForApproval, "Approval survives restart")
            try append(path, type: "response_item", payload: ["type": "custom_tool_call_output", "call_id": "approval", "output": [["type": "input_text", "text": "Script running with cell ID 42"]]])
            actual = try await state()
            XCTAssertEqual(actual, .waitingForApproval)
            try append(path, type: "response_item", payload: ["type": "function_call", "name": "wait", "call_id": "wait", "arguments": #"{"cell_id":"42"}"#])
            try append(path, type: "response_item", payload: ["type": "function_call_output", "call_id": "wait", "output": "Script running with cell ID 42"])
            actual = try await state()
            XCTAssertEqual(actual, .waitingForApproval)
            try append(path, type: "response_item", payload: ["type": "function_call", "name": "functions.wait", "call_id": "final", "arguments": #"{"cell_id":"42"}"#])
            provider = CodexProvider(home: home.path)
            actual = try await state()
            XCTAssertEqual(actual, .waitingForApproval)
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
}
