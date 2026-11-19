import Foundation
import XCTest
@testable import AgentHud

final class DesktopActivityTests: XCTestCase {
    private let uuid = "12345678-1234-1234-1234-123456789abc"
    private let producer = "aaaaaaaa-1234-1234-1234-123456789abc"
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ state: AgentState = .unknown, id: String? = nil, type: AgentType = .codex) -> AgentSession {
        AgentSession(id: id ?? "codex:\(uuid)", agentType: type, state: state,
            hasUnreadCompletion: false, completionDetectedAt: nil, processId: nil,
            projectPath: "/missing/project", worktreePath: nil, sessionTitle: "Fixture", currentTask: nil,
            startedAt: epoch, lastActivityAt: epoch, isActive: true, wakeupAt: nil,
            hasBackgroundTasks: false, parentSessionId: nil, rateLimitResetAt: nil,
            tokens5h: 0, tokensWeek: 0, primaryLimit: nil, secondaryLimit: nil)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-activity-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func write(_ record: ActivityRecord, to root: URL) throws {
        let url = root.appendingPathComponent("\(record.app)-\(record.sessionID).json")
        try JSONEncoder().encode(record).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func record(_ state: String, seconds: Double = 0, sequence: Int = 1, turn: String = "turn1") -> ActivityRecord {
        let timestamp = epoch.addingTimeInterval(seconds).timeIntervalSince1970 * 1000
        return ActivityRecord(version: 1, app: "chatGPT", sessionID: uuid, state: state,
            producer: producer, eventID: "event-\(sequence)", sequence: sequence, timestamp: timestamp,
            source: "hook", validUntil: timestamp + 120_000, turnID: turn)
    }

    func testAncestorContextDoesNotReplayHistoricalCompletion() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        try write(record("completed", seconds: -7200), to: dir)
        var parent = session(.unknown); parent.isAncestorContext = true; parent.lastActivityAt = .distantPast
        let overlay = LiveActivityOverlay(roots: [dir], now: { self.epoch })
        let context = try XCTUnwrap(overlay.apply([parent]).first)
        XCTAssertEqual(context.state, .unknown); XCTAssertNil(context.completionRevision)
        let registry = AgentSessionRegistry(); registry.replace([context])
        XCTAssertFalse(registry.findSession(parent.id)!.hasUnreadCompletion)
        // Previously saved real unread evidence still survives a metadata-only context update.
        var completed = parent; completed.isAncestorContext = nil; completed.state = .completed; completed.completionRevision = "real"
        registry.replace([completed]); registry.replace([context])
        XCTAssertTrue(registry.findSession(parent.id)!.hasUnreadCompletion)
    }

    func testCompletionRequiresExplicitEvidenceAndSurvivesRestart()
 throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("completion.json")
        var now = epoch
        var registry = AgentSessionRegistry(timeProvider: { now }, storageURL: file)
        var value = session(.working)
        registry.replace([value]); value.state = .idle; registry.replace([value])
        XCTAssertFalse(try XCTUnwrap(registry.findSession(value.id)).hasUnreadCompletion)
        value.state = .completed; value.completionRevision = "result1"
        registry.replace([value])
        now = epoch.addingTimeInterval(3600)
        registry.replace([])
        XCTAssertTrue(try XCTUnwrap(registry.findSession(value.id)).hasUnreadCompletion)
        registry = AgentSessionRegistry(storageURL: file)
        XCTAssertTrue(try XCTUnwrap(registry.findSession(value.id)).hasUnreadCompletion)
        registry.acknowledgeCompletion(value.id, revision: "old-result")
        XCTAssertTrue(try XCTUnwrap(registry.findSession(value.id)).hasUnreadCompletion)
        registry.acknowledgeCompletion(value.id, revision: "result1")
        registry = AgentSessionRegistry(storageURL: file); registry.replace([value])
        XCTAssertFalse(try XCTUnwrap(registry.findSession(value.id)).hasUnreadCompletion)
        value.completionRevision = "result2"; registry.replace([value])
        registry.acknowledgeCompletion(value.id, revision: "result1")
        XCTAssertTrue(try XCTUnwrap(registry.findSession(value.id)).hasUnreadCompletion)
        value.state = .error; registry.replace([value])
        XCTAssertEqual(registry.findSession(value.id)?.displayState, .error)
        XCTAssertFalse(try XCTUnwrap(registry.findSession(value.id)).hasUnreadCompletion)
    }

    func testNativeRowsAreNotPersistedOrRetainedAfterTheirAXIdentityExpires() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("completion.json")
        let registry = AgentSessionRegistry(storageURL: file)
        var native = session(.completed, id: "desktop:ephemeral", type: .claudeCode)
        native.nativeThreadID = "ephemeral"; native.completionRevision = "result1"
        registry.replace([native])
        XCTAssertTrue(try XCTUnwrap(registry.findSession(native.id)).hasUnreadCompletion)
        XCTAssertTrue(AgentSessionRegistry(storageURL: file).getAllAgents().isEmpty)
        native.state = .idle; native.sourceRead = true
        registry.replace([native])
        XCTAssertFalse(try XCTUnwrap(registry.findSession(native.id)).hasUnreadCompletion)
        native.state = .completed; native.sourceRead = false; native.completionRevision = "result2"
        registry.replace([native]); registry.replace([])
        XCTAssertTrue(registry.getAllAgents().isEmpty)
    }

    func testRegistryRejectsSymlinkAndPublicFile() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("completion.json")
        let registry = AgentSessionRegistry(storageURL: file)
        var value = session(.completed); value.completionRevision = "result"
        registry.replace([value])
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertTrue(AgentSessionRegistry(storageURL: link).getAllAgents().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertTrue(AgentSessionRegistry(storageURL: file).getAllAgents().isEmpty)
    }

    func testRunningLeaseExpiryAndRemovalNeverCreateCompletion() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        var now = epoch
        let overlay = LiveActivityOverlay(roots: [dir], now: { now })
        try write(record("running"), to: dir)
        XCTAssertEqual(overlay.apply([session(.working)]).first?.state, .working)
        now = epoch.addingTimeInterval(121)
        XCTAssertEqual(overlay.apply([session(.working)]).first?.state, .unknown)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("chatGPT-\(uuid).json"))
        XCTAssertEqual(overlay.apply([session(.working)]).first?.state, .unknown)
        XCTAssertNil(overlay.apply([session(.working)]).first?.completionRevision)
    }

    func testNewestCollectorWinsWithItsOwnLeaseAndOldRunningCannotOverrideTerminal() throws {
        let a = try root(), b = try root()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let overlay = LiveActivityOverlay(roots: [a, b], now: { self.epoch.addingTimeInterval(10) })
        try write(record("running", seconds: -200), to: a)
        try write(record("completed", seconds: 2, sequence: 2), to: b)
        var metadataOnly = session()
        metadataOnly.lastActivityAt = epoch.addingTimeInterval(8)
        XCTAssertEqual(overlay.apply([metadataOnly]).first?.state, .completed, "A metadata timestamp is not a newer execution event")
        try write(record("running", seconds: 3, sequence: 3), to: a)
        var terminal = session(.stopped); terminal.lastActivityAt = epoch.addingTimeInterval(3.5)
        XCTAssertEqual(overlay.apply([terminal]).first?.state, .stopped)
        terminal.state = .rateLimited
        XCTAssertEqual(overlay.apply([terminal]).first?.state, .rateLimited)
        var waiting = session(.waitingForInput); waiting.needsInput = true
        try write(record("failed", seconds: 6, sequence: 4), to: b)
        XCTAssertEqual(overlay.apply([waiting]).first?.displayState, .error)
    }

    func testQuestionAndExecutionAreIndependentAndCompletionRevisionMatchesLog() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let overlay = LiveActivityOverlay(roots: [dir], now: { self.epoch.addingTimeInterval(10) })
        var value = session(.working); value.needsInput = true; value.currentTurnID = "turn1"
        try write(record("running"), to: dir)
        let running = try XCTUnwrap(overlay.apply([value]).first)
        XCTAssertEqual(running.displayState, .working); XCTAssertTrue(running.needsInput)
        try write(record("completed", seconds: 1, sequence: 2), to: dir)
        let complete = try XCTUnwrap(overlay.apply([value]).first)
        XCTAssertEqual(complete.completionRevision, "turn:turn1")
        XCTAssertEqual(complete.displayState, .waitingForInput)
        let registry = AgentSessionRegistry(); registry.replace([complete])
        registry.acknowledgeCompletion(value.id, revision: complete.completionRevision)
        value.state = .completed; value.completionRevision = "turn:turn1"; value.lastActivityAt = epoch.addingTimeInterval(4)
        registry.replace(overlay.apply([value]))
        XCTAssertFalse(try XCTUnwrap(registry.findSession(value.id)).hasUnreadCompletion)
        value.state = .working; value.currentTurnID = "turn2"
        XCTAssertEqual(overlay.apply([value]).first?.state, .working)
    }

    func testInvalidOrReorderedRecordsCannotReplaceCurrentEvent() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let overlay = LiveActivityOverlay(roots: [dir], now: { self.epoch.addingTimeInterval(10) })
        try write(record("completed", seconds: 5, sequence: 2), to: dir)
        XCTAssertEqual(overlay.apply([session()]).first?.state, .completed)
        try write(record("running", sequence: 1), to: dir)
        XCTAssertEqual(overlay.apply([session()]).first?.state, .completed)
        XCTAssertThrowsError(try ActivityFileStore.decode(JSONEncoder().encode(record("running")), sessionID: UUID().uuidString, app: .chatGPT, now: epoch))
        XCTAssertFalse(ActivityFileStore.validSessionID("ses_../escape"))
    }

    func testDesktopFirstRoutingUsesExactIdentityAndDoesNotRequireProject() throws {
        let value = session()
        let routes = ConversationRoutePolicy.routes(for: value, preference: .automatic,
            runningBundles: ["com.openai.codex"], pathExists: { _ in false })
        XCTAssertEqual(routes.first, .codex(URL(string: "codex://threads/\(uuid)")!))
        XCTAssertEqual(routes.count, 2)
        let fallback = ConversationRoutePolicy.routes(for: value, preference: .automatic, runningBundles: [], pathExists: { _ in false })
        XCTAssertEqual(fallback.count, 1)
        guard case .vscode = fallback[0] else { return XCTFail("Expected extension fallback") }
        XCTAssertTrue(ConversationRoutePolicy.routes(for: session(id: "codex:../../bad"), preference: .automatic,
            runningBundles: ["com.openai.codex"], pathExists: { _ in false }).isEmpty)
        let claude = session(id: "claude:\(uuid)", type: .claudeCode)
        let claudeRoutes = ConversationRoutePolicy.routes(for: claude, preference: .automatic,
            runningBundles: ["com.anthropic.claudefordesktop"], pathExists: { _ in false })
        XCTAssertEqual(claudeRoutes.first, .claudeLocal(uuid)) // Runtime must resolve the explicit desktop metadata link.
        guard case .vscode = claudeRoutes.last else { return XCTFail("Expected extension fallback after verified desktop lookup") }
        var native = session(id: "desktop:row", type: .claudeCode)
        native.nativeThreadID = "row"; native.processId = 42; native.projectPath = nil
        XCTAssertEqual(ConversationRoutePolicy.routes(for: native, preference: .automatic,
            runningBundles: ["com.anthropic.claudefordesktop"], pathExists: { _ in false }), [.nativeClaude("row", 42)])
        XCTAssertFalse(ConversationOpenResult.extensionRequested.acknowledgesCompletion)
        XCTAssertFalse(ConversationOpenResult.projectOnly.acknowledgesCompletion)
        XCTAssertFalse(ConversationOpenResult.failed.acknowledgesCompletion)
    }

    @MainActor func testRouterFallsBackOnlyWhenDesktopFails() async {
        let routes: [ConversationRoute] = [.codex(URL(string: "codex://threads/\(uuid)")!), .vscode(nil, "/fixture")]
        var calls = 0
        let result = await ConversationRouter.run(routes: routes) { _ in
            calls += 1; return calls == 1 ? .failed : .projectOnly
        }
        XCTAssertEqual(calls, 2); XCTAssertEqual(result, .projectOnly)
        calls = 0
        _ = await ConversationRouter.run(routes: routes) { _ in calls += 1; return .desktopRouteAccepted }
        XCTAssertEqual(calls, 1)
    }
    func testOpenCodeRequiresLiveProducerHeartbeat() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        var now = epoch
        let overlay = LiveActivityOverlay(roots: [dir], now: { now })
        let value = session(id: "opencode:ses_Fixture", type: .openCode)
        let event = ActivityRecord(version: 1, app: "openCode", sessionID: "ses_Fixture", state: "running",
            producer: producer, eventID: "event", sequence: 1, timestamp: epoch.timeIntervalSince1970 * 1000,
            source: nil, validUntil: nil, turnID: nil)
        try write(event, to: dir)
        XCTAssertEqual(overlay.apply([value]).first?.state, .unknown)
        let heartbeat = dir.appendingPathComponent("openCode-heartbeat-\(producer).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "app": "openCode", "producer": producer,
            "timestamp": epoch.timeIntervalSince1970 * 1000]).write(to: heartbeat)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: heartbeat.path)
        XCTAssertEqual(overlay.apply([value]).first?.state, .working)
        now = epoch.addingTimeInterval(11)
        XCTAssertEqual(overlay.apply([value]).first?.state, .unknown)
    }

    func testClaudeSidebarRequiresMatchingMenuAndExplicitStatus() {
        func extract(_ title: String, menu: String) -> [ThreadItem] {
            ThreadExtractor.extract(app: .claude, sidebar: SidebarNode("side", children: [
                SidebarNode("row", children: [SidebarNode("button", role: "AXButton", title: title),
                    SidebarNode("menu", role: "AXPopUpButton", title: menu)])
            ]), generation: "fixture")
        }
        XCTAssertEqual(extract("Fixture 실행 중", menu: "Fixture에 대한 더 많은 옵션").first?.title, "Fixture")
        XCTAssertTrue(extract("Fixture 실행 중", menu: "Other에 대한 더 많은 옵션").isEmpty)
        let title = extract("Fixture 실행 중", menu: "Fixture 실행 중에 대한 더 많은 옵션").first?.title
        XCTAssertEqual(title, "Fixture 실행 중")
        XCTAssertEqual(ThreadExtractor.claudeActivity(label: "Fixture 실행 중", title: title!), .unknown)
        XCTAssertEqual(ThreadExtractor.claudeActivity(labels: ["Fixture", "Fixture 실행 중"], title: "Fixture"), .running)
        XCTAssertEqual(ThreadExtractor.claudeActivity(labels: ["Fixture", "Fixture 읽지 않은 응답"], title: "Fixture"), .needsReview)
        XCTAssertNil(ThreadExtractor.claudeActivity(label: "Fixture 실패", title: "Fixture"))
    }

    func testIdleSidebarRowsDoNotBuryRunningOrUnreadWork() {
        let registry = AgentSessionRegistry()
        var idle = session(.idle, id: "desktop:idle", type: .claudeCode)
        idle.lastActivityAt = epoch.addingTimeInterval(100)
        var completed = session(.completed, id: "codex:complete")
        completed.completionRevision = "result"
        let working = session(.working)
        registry.replace([idle, completed, working])
        XCTAssertEqual(registry.getAllAgents().map(\.id), [working.id, completed.id, idle.id])
    }

}

extension DesktopActivityTests {
    func testLateRunningHookCannotReplaceSavedFinalFromSameTurn() throws {
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(record("running", seconds: 1), to: dir)
        var final = session(.completed)
        final.currentTurnID = "turn1"
        final.completionRevision = "turn:turn1"
        let overlay = LiveActivityOverlay(roots: [dir], now: { self.epoch.addingTimeInterval(130) })
        XCTAssertEqual(overlay.apply([final]).first?.state, .completed)
    }
}
