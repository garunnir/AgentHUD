import Foundation
import XCTest
@testable import AgentHud

final class ClaudeMergeTests: XCTestCase {
    let uuid = "12345678-1234-1234-1234-123456789abc"
    func session(_ id: String, native: String? = nil) -> AgentSession {
        var s = AgentSession(id: id, agentType: .claudeCode, state: .working, hasUnreadCompletion: false,
            completionDetectedAt: nil, processId: native == nil ? 11 : 22, projectPath: native == nil ? "/fixture" : nil,
            worktreePath: nil, sessionTitle: "Same title", currentTask: nil, startedAt: Date(), lastActivityAt: Date(),
            isActive: true, wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: nil, rateLimitResetAt: nil,
            tokens5h: 100, tokensWeek: 200, primaryLimit: nil, secondaryLimit: nil)
        if let native { s.claudeDesktopID = "local_" + native; s.claudeCanonicalID = native }
        return s
    }
    func testOnlyVerifiedIdentityMergesAndNativePIDRoutesFirst() {
        let local = session("claude:" + uuid)
        var native = session("claude:" + uuid, native: uuid)
        let unrelated = session("claude:" + UUID().uuidString.lowercased(), native: uuid)
        XCTAssertEqual(ClaudeSessionCoalescer.merge([local, unrelated]).count, 2) // Equal titles are not evidence.
        native.claudeCanonicalID = uuid.uppercased()
        let merged = ClaudeSessionCoalescer.merge([local, native])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, local.id); XCTAssertEqual(merged[0].projectPath, "/fixture")
        XCTAssertEqual(merged[0].processId, 11); XCTAssertEqual(merged[0].nativeProcessId, 22)
        XCTAssertEqual(merged[0].claudeDesktopID, "local_" + uuid); XCTAssertEqual(merged[0].tokens5h, 100)
        XCTAssertEqual(ConversationRoutePolicy.routes(for: merged[0], preference: .automatic,
            runningBundles: ["com.anthropic.claudefordesktop"], pathExists: { _ in false }).first, .claudeDesktop("local_" + uuid))
        XCTAssertEqual(ConversationRoutePolicy.routes(for: local, preference: .automatic, runningBundles: ["com.anthropic.claudefordesktop"], pathExists: { _ in false }).first, .claudeLocal(uuid))
        let other = session("claude:" + UUID().uuidString.lowercased(), native: uuid)
        XCTAssertEqual(ClaudeSessionCoalescer.merge([local, other]).count, 2)
        var duplicate = native; duplicate.claudeDesktopID = "local_" + UUID().uuidString.lowercased()
        XCTAssertEqual(ClaudeSessionCoalescer.merge([local, native, duplicate]).count, 3)
    }
    func testNativeReadAndCompletionDoNotDuplicateLocalResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-merge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let registry = AgentSessionRegistry(storageURL: file)
        var local = session("claude:" + uuid); local.state = .completed; local.completionRevision = "local-old"
        var native = session("claude:" + uuid, native: uuid); native.claudeCanonicalID = uuid
        native.state = .completed; native.completionRevision = "native-result"
        registry.replace([local, native])
        registry.replace(ClaudeSessionCoalescer.merge([local, native]))
        XCTAssertEqual(registry.getAllAgents().count, 1)
        XCTAssertEqual(registry.findSession(local.id)?.completionRevision, "native-result")
        XCTAssertTrue(registry.findSession(local.id)!.hasUnreadCompletion)
        let restored = AgentSessionRegistry(storageURL: file)
        XCTAssertEqual(restored.getAllAgents().count, 1)
        XCTAssertNil(restored.findSession(local.id)?.nativeThreadID)
        XCTAssertNil(restored.findSession(local.id)?.nativeProcessId)
        restored.replace([]); XCTAssertNil(restored.findSession(local.id)?.nativeThreadID)
        native.state = .idle; native.sourceRead = true; native.completionRevision = nil
        registry.replace(ClaudeSessionCoalescer.merge([local, native]))
        XCTAssertFalse(registry.findSession(local.id)!.hasUnreadCompletion)
        registry.replace([local]); XCTAssertFalse(registry.findSession(local.id)!.hasUnreadCompletion)
        let reread = AgentSessionRegistry(storageURL: file); reread.replace([local])
        XCTAssertFalse(reread.findSession(local.id)!.hasUnreadCompletion)
        for state in [AgentState.waitingForApproval, .waitingForInput, .error, .rateLimited] {
            var stronger = local; stronger.state = state
            XCTAssertEqual(ClaudeSessionCoalescer.merge([stronger, native])[0].state, state)
        }
        local.state = .waitingForApproval; native.state = .working; native.sourceRead = false
        XCTAssertEqual(ClaudeSessionCoalescer.merge([local, native])[0].state, .waitingForApproval)
        XCTAssertEqual(SessionListPolicy.rows(ClaudeSessionCoalescer.merge([local, native])).count, 1)
    }
    func testClosedDesktopRowKeepsCanonicalMenuTitleWithoutClaimingCompletion() {
        let tree = SidebarNode("sidebar", children: [SidebarNode("pair", children: [
            SidebarNode("button", role: "AXButton", title: "Fixture 마감"),
            SidebarNode("menu", role: "AXPopUpButton", title: "Fixture에 대한 더 많은 옵션")
        ])])
        let rows = ThreadExtractor.extract(app: .claude, sidebar: tree, generation: "g")
        XCTAssertEqual(rows.map(\.title), ["Fixture"])
        XCTAssertNil(ThreadExtractor.claudeActivity(label: "Fixture 마감", title: "Fixture"))
        XCTAssertTrue(ThreadExtractor.claudeRowMatchesTitle("Fixture 마감", title: "Fixture"))
        XCTAssertTrue(ThreadExtractor.claudeRowMatchesTitle("Fixture 실행 중", title: "Fixture"))
        XCTAssertFalse(ThreadExtractor.claudeRowMatchesTitle("Other 마감", title: "Fixture"))
    }

    func testCanonicalURLAndMetadataValidation() throws {
        let id = "local_" + uuid
        XCTAssertEqual(ClaudeDesktopLink.desktopID(from: "https://claude.ai/epitaxy/" + id), id)
        for url in ["https://claude.ai.evil/epitaxy/" + id, "https://claude.ai/epitaxy/" + id + "?x=y", "https://claude.ai/epitaxy/bad", "https://user@claude.ai/epitaxy/" + id] {
            XCTAssertNil(ClaudeDesktopLink.desktopID(from: url))
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        let folder = root.appendingPathComponent(UUID().uuidString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["sessionId": id, "cliSessionId": uuid, "title": "Fixture"])
        try data.write(to: folder.appendingPathComponent(id + ".json"))
        let provider = ClaudeDesktopMetadataProvider(home: home.path, client: NativeSidebarClient())
        XCTAssertEqual(provider.readRecords().map(\.sessionId), [id])
        XCTAssertEqual(provider.readRecords().map(\.sessionId), [id]) // Cached metadata keeps canonical identity.
        XCTAssertEqual(ClaudeDesktopLink.read(id, home: home.path)?.cliSessionId, uuid)
        XCTAssertEqual(ClaudeDesktopLink.find(cliID: uuid, home: home.path)?.sessionId, id)
        let other = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try data.write(to: other.appendingPathComponent(id + ".json"))
        XCTAssertTrue(provider.readRecords().isEmpty)
        XCTAssertNil(ClaudeDesktopLink.read(id, home: home.path)) // Multiple profile matches fail closed.
        XCTAssertNil(ClaudeDesktopLink.find(cliID: uuid, home: home.path))
        XCTAssertNil(ClaudeDesktopLink.read("../" + id, home: home.path))
    }
}
