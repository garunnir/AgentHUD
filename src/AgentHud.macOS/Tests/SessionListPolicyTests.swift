import Foundation
import XCTest
@testable import AgentHud

final class SessionListPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 100_000)
    func session(_ id: String, age: TimeInterval = 0, parent: String? = nil) -> AgentSession {
        AgentSession(id: id, agentType: .codex, state: .idle, hasUnreadCompletion: false,
            completionDetectedAt: nil, processId: nil, projectPath: nil, worktreePath: nil,
            sessionTitle: id, currentTask: nil, startedAt: now.addingTimeInterval(-age),
            lastActivityAt: now.addingTimeInterval(-age), isActive: false, wakeupAt: nil,
            hasBackgroundTasks: false, parentSessionId: parent, rateLimitResetAt: nil,
            tokens5h: 0, tokensWeek: 0, primaryLimit: nil, secondaryLimit: nil)
    }
    func testLegacyUppercaseCodexCompletionRestoresUnderCanonicalID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pending.json")
        let uuid = UUID().uuidString
        var old = session("codex:" + uuid)
        old.state = .completed
        old.completionRevision = "turn:fixture"
        AgentSessionRegistry(storageURL: file).replace([old])
        let restored = AgentSessionRegistry(storageURL: file)
        let id = "codex:" + uuid.lowercased()
        XCTAssertEqual(restored.getAllAgents().map(\.id), [id])
        var current = old
        current.id = id
        restored.replace([current])
        XCTAssertEqual(restored.getAllAgents().map(\.id), [id])
        XCTAssertTrue(try XCTUnwrap(restored.findSession(id)).hasUnreadCompletion)
        restored.acknowledgeCompletion(id, revision: current.completionRevision)
        restored.replace([current])
        XCTAssertFalse(try XCTUnwrap(restored.findSession(id)).hasUnreadCompletion)
    }

    func testRecentWindowAndNativeInitialDiscoveryAreDifferent() {
        var rows = (0..<10).map { i -> AgentSession in
            var s = session("native:\(i)"); s.nativeThreadID = s.id; s.nativeSidebarRank = i
            return s // All were discovered now; this is not source activity.
        }
        rows += [session("old", age: 3601), session("recent", age: 3599)]
        var actual = SessionListPolicy.rows(rows, now: now).map(\.id)
        XCTAssertEqual(actual.count, 1); XCTAssertFalse(actual.contains("native:8")); XCTAssertFalse(actual.contains("old"))
        rows[0].nativeSelected = true
        XCTAssertFalse(SessionListPolicy.rows(rows, now: now).map(\.id).contains("native:0"))
        rows[8].state = .working; rows[9].sourceUnread = true
        actual = SessionListPolicy.rows(rows, now: now).map(\.id)
        XCTAssertTrue(actual.contains("native:8")); XCTAssertTrue(actual.contains("native:9"))
        rows[7].nativeActivityAt = now.addingTimeInterval(-20)
        XCTAssertTrue(SessionListPolicy.rows(rows, now: now).map(\.id).contains("native:7"))
        rows[7].nativeActivityAt = now.addingTimeInterval(-3601)
        XCTAssertFalse(SessionListPolicy.rows(rows, now: now).map(\.id).contains("native:7"))
    }
    func testHiddenNativeChildrenDoNotConsumeMainThreadQuota() {
        var rows = (0..<6).map { i -> AgentSession in
            var s = session("native:\(i)"); s.nativeThreadID = s.id; s.nativeSidebarRank = i
            s.isSubagent = i < 5; return s
        }
        XCTAssertTrue(SessionListPolicy.rows(rows, now: now).isEmpty)
        rows[5].nativeSidebarRank = nil
        XCTAssertTrue(SessionListPolicy.rows(rows, now: now).isEmpty)
    }

    func testCodexDiscoveryRetainsMetadataOnlyParentOutsideWindow() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-family-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let parent = "12345678-1234-1234-1234-123456789abc"
        let child = "87654321-1234-1234-1234-123456789abc"
        let old = Date().addingTimeInterval(-7200)
        func write(_ id: String, parentID: String?, at: Date) throws {
            var payload: [String: Any] = ["id": id, "timestamp": ISO8601DateFormatter().string(from: at)]
            if let parentID { payload["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": parentID]]]; payload["agent_nickname"] = "Fixture worker" }
            let data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "timestamp": ISO8601DateFormatter().string(from: at), "payload": payload])
            let file = root.appendingPathComponent("rollout-\(id).jsonl")
            try (data + Data([10])).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: file.path)
        }
        try write(parent, parentID: nil, at: old); try write(child, parentID: parent, at: Date())
        let provider = CodexProvider(home: home.path, activeWindow: 60)
        let found = try await provider.discover()
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first { $0.id == "codex:\(parent)" }?.state, .unknown)
        XCTAssertEqual(found.first { $0.id == "codex:\(child)" }?.sessionTitle, "Fixture worker")
        XCTAssertTrue(SessionListPolicy.rows(found).isEmpty) // Recent child metadata is not running work.
        let working = found.map { value -> AgentSession in
            var value = value
            if value.id == "codex:\(child)" { value.state = .working }
            return value
        }
        XCTAssertEqual(SessionListPolicy.rows(working).map(\.id), ["codex:\(parent)"])
        let cached = try await provider.discover()
        XCTAssertEqual(cached.first { $0.id == "codex:\(child)" }?.sessionTitle, "Fixture worker")
        try write(child, parentID: parent, at: old)
        // Pending completions restored by the registry still request their parent's context.
        let restored = try await CodexProvider(home: home.path, activeWindow: 60, retainedParentIDs: { ["codex:\(parent)"] }).discover()
        XCTAssertEqual(restored.map(\.id), ["codex:\(parent)"])
        XCTAssertEqual(restored.first?.lastActivityAt, .distantPast)
    }

    func testOnlyRootShowsNestedExecutionAndStopsWithoutFabricatingCompletion() {
        let parent = session("p", age: 7200)
        let child = session("c", age: 7200, parent: "p")
        var grandchild = session("g", parent: "c"); grandchild.state = .working
        var rows = SessionListPolicy.rows([grandchild, child, parent], now: now)
        XCTAssertEqual(rows.map(\.id), ["p"])
        XCTAssertTrue(rows[0].hasRunningDescendants)
        XCTAssertEqual(rows[0].statusName, "Working")
        XCTAssertEqual(rows[0].session.state, .idle)
        XCTAssertFalse(rows[0].session.hasUnreadCompletion)
        XCTAssertTrue(SessionListPolicy.rows([grandchild, child, parent], hidden: ["p"], now: now).isEmpty)
    let legacyHidden = SessionListPolicy.rows([grandchild, child, parent], hidden: ["c", "g"], now: now)
    XCTAssertEqual(legacyHidden.map(\.id), ["p"]); XCTAssertTrue(legacyHidden[0].hasRunningDescendants)
        for state in [AgentState.idle, .completed, .waitingForInput, .waitingForApproval, .unknown, .error] {
            grandchild.state = state; grandchild.hasUnreadCompletion = state == .completed
            rows = SessionListPolicy.rows([grandchild, child, parent], now: now)
            XCTAssertTrue(rows.isEmpty, "A hidden child in \(state) must not keep its old root visible/spinning")
        }
        for state in [AgentState.working, .thinking, .starting] {
            grandchild.state = state
            XCTAssertTrue(SessionListPolicy.rows([grandchild, child, parent], now: now)[0].hasRunningDescendants)
        }
    }
    func testChildExecutionPreservesParentWaitingAndCompletionEvidence() {
        var parent = session("p"); parent.state = .waitingForApproval
        var child = session("c", parent: "p"); child.state = .working
        var row = SessionListPolicy.rows([child, parent], now: now)[0]
        XCTAssertTrue(row.hasRunningDescendants); XCTAssertEqual(row.statusName, "WaitingForApproval")
        parent.state = .completed; parent.hasUnreadCompletion = true; parent.completionRevision = "own-result"
        row = SessionListPolicy.rows([child, parent], now: now)[0]
        XCTAssertEqual(row.statusName, "Working"); XCTAssertTrue(row.session.hasUnreadCompletion)
        XCTAssertEqual(row.session.completionRevision, "own-result")
        child.state = .idle
        row = SessionListPolicy.rows([child, parent], now: now)[0]
        XCTAssertFalse(row.hasRunningDescendants); XCTAssertEqual(row.statusName, "Completed")
    }
    func testUnknownParentSelfCycleAndCrossAgentAreNotRoots() {
        var orphan = session("orphan"); orphan.isSubagent = true
        var cross = session("cross", parent: "root"); cross = AgentSessionCopy.withAmp(cross)
        let rows = [orphan, session("self", parent: "self"), session("a", parent: "b"),
                    session("b", parent: "a"), session("missing", parent: "absent"), cross, session("root")]
        let running = rows.map { value -> AgentSession in var value = value; if value.isChildSession { value.state = .working }; return value }
        let projected = SessionListPolicy.rows(running, now: now)
        XCTAssertEqual(projected.map(\.id), ["root"])
        XCTAssertFalse(projected[0].hasRunningDescendants)
    }
    func testCodexFamilyUsesExplicitMatchingIDsOnly() {
        let parent = "12345678-1234-1234-1234-123456789abc"
        let own = "87654321-1234-1234-1234-123456789abc"
        let nested: [String: Any] = ["source": ["subagent": ["thread_spawn": ["parent_thread_id": parent]]]]
        XCTAssertTrue(CodexFamily.isChild(nested)); XCTAssertEqual(CodexFamily.parentID(nested, ownID: own), "codex:\(parent)")
        var mismatch = nested; mismatch["parent_thread_id"] = own
        XCTAssertNil(CodexFamily.parentID(mismatch, ownID: own))
        XCTAssertNil(CodexFamily.parentID(["parent_thread_id": own], ownID: own))
        XCTAssertNil(CodexFamily.parentID(["parent_thread_id": "not-an-id"], ownID: own))
        XCTAssertFalse(CodexFamily.isChild(["forked_from_id": parent, "agent_nickname": "worker"]))
        XCTAssertFalse(CodexFamily.isChild(["parent_thread_id": NSNull(), "source": ["subagent": NSNull()]]))
    }
    func testParentlessSubagentCannotResumeOrNotify() {
        var child = session("codex:12345678-1234-1234-1234-123456789abc")
        child.isSubagent = true; child.rateLimitResetAt = now.addingTimeInterval(-120)
        let resumer = AutoResumer(logDirectory: FileManager.default.temporaryDirectory, now: { self.now }, locate: { _ in nil })
        XCTAssertFalse(resumer.isDue(child)); XCTAssertNil(resumer.launch(for: child))
        XCTAssertTrue(RateLimitNotifier(now: { self.now }).takeDue([child]).isEmpty)
    }
    func testHiddenChildCompletionDoesNotCreateParentReviewOrPersistUnread() {
        let registry = AgentSessionRegistry(timeProvider: { self.now })
        var parent = session("p"); parent.state = .completed; parent.completionRevision = "p1"
        var child = session("c", parent: "p"); child.state = .completed; child.completionRevision = "c1"
        registry.replace([parent, child]); registry.acknowledgeCompletion("p", revision: "p1")
        let folded = SessionListPolicy.rows(registry.getAllAgents(), now: now)
        XCTAssertEqual(folded.count, 1); XCTAssertFalse(folded[0].hasRunningDescendants)
        XCTAssertFalse(registry.findSession("c")!.hasUnreadCompletion)
        registry.replace([parent]); XCTAssertNil(registry.findSession("c"))
    }
    func testLegacyChildCompletionsDoNotRestoreOrConsumeAncestorBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-root-only-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let old = (0..<70).map { i -> AgentSession in
            var value = session("child\(i)", age: 7200, parent: "parent\(i)")
            value.state = .completed; value.hasUnreadCompletion = true; value.completionRevision = "old"
            return value
        }
        let pending = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending))
        try JSONSerialization.data(withJSONObject: ["acknowledged": [:], "pending": encoded]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let registry = AgentSessionRegistry(timeProvider: { self.now }, storageURL: file)
        XCTAssertTrue(registry.getAllAgents().isEmpty)
        XCTAssertTrue(registry.getByAgentType(.codex).filter(\.hasUnreadCompletion).compactMap(\.parentSessionId).isEmpty)
        var child = session("live", parent: "root"); child.state = .working
        let root = session("root", age: 7200)
        registry.replace(old + [child, root])
        let rows = SessionListPolicy.rows(registry.getAllAgents(), now: now)
        XCTAssertEqual(rows.map(\.id), ["root"]); XCTAssertTrue(rows[0].hasRunningDescendants)
        registry.replace([child, root])
        XCTAssertEqual(Set(registry.getAllAgents().map(\.id)), ["live", "root"])
        let restarted = AgentSessionRegistry(timeProvider: { self.now }, storageURL: file)
        XCTAssertTrue(restarted.getAllAgents().isEmpty)
    }

}

private enum AgentSessionCopy {
    static func withAmp(_ source: AgentSession) -> AgentSession {
        // Codable round trip changes only the immutable provider in this cross-app fixture.
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        object["agentType"] = AgentType.amp.rawValue
        return try! JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
