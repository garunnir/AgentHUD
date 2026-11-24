import Foundation
import XCTest
@testable import AgentHud

final class ClaudeDesktopMetadataTests: XCTestCase {
    let uuid = "12345678-1234-1234-1234-123456789abc"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func metadata(_ changes: [String: Any] = [:]) throws -> ClaudeDesktopLink.Metadata {
        var values: [String: Any] = ["sessionId": "local_" + uuid, "cliSessionId": uuid,
            "title": "Same title", "cwd": "/fixture", "lastActivityAt": 1_799_999_900_000.0, "completedTurns": 4]
        values.merge(changes) { _, new in new }
        return try JSONDecoder().decode(ClaudeDesktopLink.Metadata.self, from: JSONSerialization.data(withJSONObject: values))
    }
    func provider() -> ClaudeDesktopMetadataProvider { ClaudeDesktopMetadataProvider(home: "/nonexistent-fixture", client: NativeSidebarClient()) }
    func testCanonicalMetadataKeepsIdentityAcrossTitleChangesAndNoInitialCompletion() throws {
        let p = provider(), first = try metadata()
        let initial = p.project([first], pid: 22, now: now)
        XCTAssertEqual(initial.count, 1); XCTAssertEqual(initial[0].id, "claude:" + uuid)
        XCTAssertEqual(initial[0].state, .unknown); XCTAssertNil(initial[0].completionRevision)
        let renamed = p.project([try metadata(["title": "Renamed"])], pid: 22, now: now)
        XCTAssertEqual(renamed[0].id, initial[0].id); XCTAssertEqual(renamed[0].sessionTitle, "Renamed")
        let other = try metadata(["sessionId": "local_" + UUID().uuidString.lowercased(), "cliSessionId": UUID().uuidString.lowercased()])
        XCTAssertEqual(p.project([first, other], pid: 22, now: now).count, 2)
    }
    func testOnlyCounterIncreaseCompletesAndNewActivityDoesNotReplayOldResult() throws {
        let p = provider(), id = "local_" + uuid
        _ = p.project([try metadata()], pid: 22, now: now)
        let done = p.project([try metadata(["completedTurns": 5])], pid: 22, now: now)[0]
        XCTAssertEqual(done.state, .completed); XCTAssertNotNil(done.completionRevision)
        let work = p.project([try metadata(["completedTurns": 5, "lastActivityAt": 1_799_999_950_000.0])], pid: 22, now: now, working: [id])[0]
        XCTAssertEqual(work.state, .working); XCTAssertNil(work.completionRevision)
        let stopped = p.project([try metadata(["completedTurns": 5, "lastActivityAt": 1_799_999_950_000.0])], pid: 22, now: now)[0]
        XCTAssertEqual(stopped.state, .unknown); XCTAssertNil(stopped.completionRevision)
        XCTAssertEqual(p.project([try metadata(["interruptedAwaitingPerson": true])], pid: 22, now: now)[0].state, .waitingForInput)
    }
    func testFiltersDatesArchivesChildrenAndAmbiguousCLIIdentity() throws {
        let p = provider()
        XCTAssertTrue(p.project([try metadata(["isArchived": true]), try metadata(["lastActivityAt": 1_900_000_000_000.0])], pid: 22, now: now).isEmpty)
        let a = try metadata(), b = try metadata(["sessionId": "local_" + UUID().uuidString.lowercased()])
        let ambiguous = p.project([a, b], pid: 22, now: now)
        XCTAssertEqual(Set(ambiguous.map(\.id)).count, 2)
        XCTAssertTrue(ambiguous.allSatisfy { $0.claudeCanonicalID == nil })
        let child = p.project([try metadata(["spawnedFrom": ["userFork": false]])], pid: 22, now: now)[0]
        XCTAssertTrue(child.isChildSession); XCTAssertTrue(SessionListPolicy.rows([child]).isEmpty)
        XCTAssertFalse(p.project([try metadata(["spawnedFrom": ["userFork": true]])], pid: 22, now: now)[0].isChildSession)
    }
    func testOlderMetadataCompletionAndFocusCannotConsumeNewLocalResult() throws {
        let fixture = ClaudeMergeTests(), p = provider()
        _ = p.project([try metadata()], pid: 22, now: now)
        let source = p.project([try metadata(["completedTurns": 5, "lastFocusedAt": 1_799_999_910_000.0])], pid: 22, now: now)[0]
        var local = fixture.session("claude:" + uuid)
        local.state = .completed; local.lastActivityAt = Date(timeIntervalSince1970: 1_799_999_890) // Metadata can lag the transcript.
        local.completionRevision = "claude-end:1799999920.0"
        let merged = ClaudeSessionCoalescer.merge([local, source])[0]
        XCTAssertEqual(merged.completionRevision, local.completionRevision); XCTAssertFalse(merged.sourceRead)
        let registry = AgentSessionRegistry(storageURL: nil)
        registry.replace([source]); registry.acknowledgeCompletion(source.id, revision: source.completionRevision)
        registry.replace([merged]); XCTAssertTrue(registry.findSession(local.id)!.hasUnreadCompletion)
        var focused = source; focused.sourceRead = true
        registry.replace(ClaudeSessionCoalescer.merge([local, focused]))
        XCTAssertFalse(registry.findSession(local.id)!.hasUnreadCompletion)
        registry.replace([local]); XCTAssertFalse(registry.findSession(local.id)!.hasUnreadCompletion)
    }
}

extension ClaudeDesktopMetadataTests {
    func testDesktopPollRecoversCurrentSavedEndTurnAfterRestart() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(uuid + ".jsonl")
        let id = UUID().uuidString.lowercased()
        let ended = now.addingTimeInterval(-6)
        let stamp = ISO8601DateFormatter().string(from: ended)
        let line: [String: Any] = ["sessionId": uuid, "uuid": id, "type": "assistant", "timestamp": stamp,
                                    "message": ["stop_reason": "end_turn"]]
        var bytes = try JSONSerialization.data(withJSONObject: line)
        bytes.append(10)
        try bytes.write(to: file)
        let m = try metadata(["lastAssistantUuid": id, "lastAssistantCliSessionId": uuid,
                              "lastActivityAt": ended.timeIntervalSince1970 * 1000,
                              "latestUserFrameAt": ended.addingTimeInterval(-5).timeIntervalSince1970 * 1000])
        let p = ClaudeDesktopMetadataProvider(home: home.path, client: NativeSidebarClient())
        let done = p.poll([m], pid: 22, now: now)[0]
        XCTAssertEqual(done.state, .completed)
        XCTAssertNotNil(done.localCompletionRevision)
        let registry = AgentSessionRegistry(storageURL: nil)
        registry.replace([done])
        registry.acknowledgeCompletion(done.id, revision: done.completionRevision)
        registry.replace(p.poll([m], pid: 22, now: now))
        XCTAssertFalse(registry.findSession(done.id)!.hasUnreadCompletion)
        let fromLocal = AgentSessionRegistry(storageURL: nil)
        var local = done
        local.completionRevision = done.localCompletionRevision
        local.localCompletionRevision = nil
        fromLocal.replace([local])
        fromLocal.acknowledgeCompletion(local.id, revision: local.completionRevision)
        fromLocal.replace([done])
        XCTAssertFalse(fromLocal.findSession(done.id)!.hasUnreadCompletion)
        let newer: [String: Any] = ["sessionId": uuid, "type": "user", "timestamp": stamp]
        bytes.append(try JSONSerialization.data(withJSONObject: newer))
        bytes.append(10)
        try bytes.write(to: file)
        let pending = p.poll([m], pid: 22, now: now)[0]
        XCTAssertEqual(pending.state, .unknown)
    }
}

extension ClaudeDesktopMetadataTests {
    func testReopeningOldAnswerKeepsItReadAcrossWarmProcessUpdates() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reply = UUID().uuidString
        let ended = now.addingTimeInterval(-86400)
        let frame: [String: Any] = ["sessionId": uuid, "uuid": reply, "type": "assistant",
            "timestamp": ISO8601DateFormatter().string(from: ended), "message": ["stop_reason": "end_turn"]]
        var bytes = try JSONSerialization.data(withJSONObject: frame)
        bytes.append(10)
        try bytes.write(to: dir.appendingPathComponent(uuid + ".jsonl"))
        let record = try metadata(["lastActivityAt": ended.timeIntervalSince1970 * 1000,
            "latestUserFrameAt": ended.addingTimeInterval(-5).timeIntervalSince1970 * 1000,
            "lastFocusedAt": now.timeIntervalSince1970 * 1000, "lastAssistantUuid": reply, "lastAssistantCliSessionId": uuid])
        let provider = ClaudeDesktopMetadataProvider(home: home.path, client: NativeSidebarClient())
        let source = provider.poll([record], pid: 22, now: now)[0]
        XCTAssertEqual(source.state, .completed)
        XCTAssertTrue(source.sourceRead)
        let registry = AgentSessionRegistry(storageURL: nil)
        var warm = ClaudeMergeTests().session("claude:" + uuid)
        warm.lastActivityAt = now
        for state in [AgentState.working, .unknown] {
            warm.state = state
            registry.replace(ClaudeSessionCoalescer.merge([warm, source]))
            XCTAssertEqual(registry.findSession(warm.id)?.displayState, .idle)
        }
        XCTAssertTrue(SessionListPolicy.rows([source], now: now).contains { $0.session.id == source.id })
    }
}

extension ClaudeDesktopMetadataTests {
    func testNewMessageAfterReadAnswerStartsWorkingWithUnchangedProcessClock() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".claude/sessions")
        let project = home.appendingPathComponent(".claude/projects/test")
        for dir in [sessions, project] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let before = Date().addingTimeInterval(-10)
        let meta: [String: Any] = ["sessionId": uuid, "pid": ProcessInfo.processInfo.processIdentifier,
            "status": "idle", "updatedAt": Int(before.timeIntervalSince1970 * 1000)]
        try JSONSerialization.data(withJSONObject: meta).write(to: sessions.appendingPathComponent("test.json"))
        let line: [String: Any] = ["sessionId": uuid, "type": "user", "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": ["role": "user", "content": "test"]]
        var bytes = try JSONSerialization.data(withJSONObject: line)
        bytes.append(10)
        try bytes.write(to: project.appendingPathComponent(uuid + ".jsonl"))
        let local = try await ClaudeCodeProvider(home: home.path).discover()
        var desktop = ClaudeMergeTests().session("claude:" + uuid, native: uuid)
        desktop.state = .completed
        desktop.localCompletionRevision = "claude-end:\(before.timeIntervalSince1970)"
        desktop.lastActivityAt = Date()
        XCTAssertEqual(ClaudeSessionCoalescer.merge(local + [desktop]).first?.state, .working)
    }
}

extension ClaudeDesktopMetadataTests {
    func testFreshDesktopPromptSupersedesOldLocalAnswerAndHistoricalRead() {
        let fixture = ClaudeMergeTests()
        var local = fixture.session("claude:" + uuid)
        let end = Date().addingTimeInterval(-10)
        local.state = .completed
        local.completionRevision = "claude-end:\(end.timeIntervalSince1970)"
        var source = fixture.session(local.id, native: uuid)
        source.state = .unknown
        source.claudeMessageAt = Date()
        source.claudePromptPending = true
        let started = ClaudeSessionCoalescer.merge([local, source])[0]
        XCTAssertEqual(started.state, .working)
        XCTAssertNil(started.completionRevision)
        source.state = .completed
        source.localCompletionRevision = "claude-end:\(end.addingTimeInterval(-10).timeIntervalSince1970)"
        source.nativeSelected = false
        source.sourceRead = true
        source.lastViewedAt = end.addingTimeInterval(-5)
        XCTAssertFalse(ClaudeSessionCoalescer.merge([local, source])[0].sourceRead)
    }
}
