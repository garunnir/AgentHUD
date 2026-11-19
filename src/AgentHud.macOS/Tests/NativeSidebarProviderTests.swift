import Foundation
import XCTest
@testable import AgentHud

final class NativeSidebarProviderTests: XCTestCase {
    private let ampURL = "https://ampcode.com/threads/T-12345678-1234-1234-1234-123456789abc"
    private func session(_ type: AgentType) -> AgentSession {
        var value = AgentSession(id: "desktop:\(type.rawValue):fixture", agentType: type, state: .unknown,
            hasUnreadCompletion: false, completionDetectedAt: nil, processId: 42, projectPath: nil,
            worktreePath: nil, sessionTitle: "Fixture", currentTask: nil, startedAt: Date(timeIntervalSince1970: 100),
            lastActivityAt: Date(timeIntervalSince1970: 100), isActive: false, wakeupAt: nil,
            hasBackgroundTasks: false, parentSessionId: nil, rateLimitResetAt: nil, tokens5h: 0, tokensWeek: 0,
            primaryLimit: nil, secondaryLimit: nil)
        value.nativeThreadID = "fixture"
        return value
    }

    func testAmpParsesOnlyCanonicalThreadLinksAndMetadataUnread() {
        let row = SidebarNode("thread", role: "AXLink", title: "Orb Executor, Executor Connected, Unread Messages\nFixture", url: ampURL)
        let sidebar = SidebarNode("root", children: [
            SidebarNode("navigation", role: "AXLink", title: "Threads", url: ampURL), row,
            SidebarNode("duplicate", role: "AXLink", title: "Fixture", url: ampURL),
            SidebarNode("space", role: "AXLink", title: "Space\nTeam", url: ampURL.replacingOccurrences(of: "12345678", with: "87654321")),
            SidebarNode("external", role: "AXLink", title: "Bad", url: ampURL.replacingOccurrences(of: "ampcode.com", with: "ampcode.com.evil.test"))
        ])
        XCTAssertEqual(ThreadExtractor.extract(app: .amp, sidebar: sidebar, generation: "g").map(\.title), ["Fixture"])
        XCTAssertEqual(ThreadExtractor.ampHasUnreadMessages(row), true)
        XCTAssertEqual(ThreadExtractor.ampHasUnreadMessages(SidebarNode("plain", role: "AXLink", title: "Orb Executor, Executor Connected\nUnread Messages", url: ampURL)), false)
        for label in ["", "Future Executor, Unread Messages\nFixture", "Orb Executor, Unknown Status\nFixture"] {
            let value = ThreadExtractor.ampHasUnreadMessages(SidebarNode("missing", role: "AXLink", title: label, url: ampURL))
            XCTAssertNil(value)
            var memory = NativeUnreadMemory(); memory.update(["a": .unread], visibleIDs: ["a"])
            memory.update(value.map { ["a": $0 ? ThreadActivity.unread : .unknown] } ?? [:], visibleIDs: ["a"])
            XCTAssertEqual(memory.value("a"), true)
        }
        let alternate = ampURL.replacingOccurrences(of: "ampcode.com", with: "AMPCODE.COM") + "/"
        let alternateRow = SidebarNode("variant", role: "AXLink", title: "Fixture", url: alternate)
        let links = ThreadExtractor.extract(app: .amp, sidebar: SidebarNode("root", children: [alternateRow, row]), generation: "g")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.url, alternate)
        XCTAssertEqual(links.first?.id, ThreadExtractor.extract(app: .amp, sidebar: sidebar, generation: "g").first?.id)
        XCTAssertEqual(links.first?.activitySessionID, ThreadExtractor.ampSessionID(ampURL))


        for invalid in [ampURL + "/other", ampURL + "?token=fixture", ampURL + "#part", "https://ampcode.com/threads/T-invalid"] {
            XCTAssertNil(ThreadExtractor.ampSessionID(invalid))
        }
    }

    func testNativeListFailureCacheExpiresAndDoesNotAcceptClockReversal() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(NativeSidebarProvider.keepCachedRows(lastSuccess: now.addingTimeInterval(-59), now: now))
        XCTAssertFalse(NativeSidebarProvider.keepCachedRows(lastSuccess: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(NativeSidebarProvider.keepCachedRows(lastSuccess: now.addingTimeInterval(1), now: now))
        // A failed scan at t59 must not extend the same cache to the ordinary t62 poll.
        XCTAssertTrue(NativeSidebarProvider.keepCachedRows(lastSuccess: now, now: now.addingTimeInterval(59)))
        XCTAssertFalse(NativeSidebarProvider.keepCachedRows(lastSuccess: now, now: now.addingTimeInterval(62)))

        XCTAssertEqual(ThreadExtractor.ampHasUnreadMessages(SidebarNode("created", role: "AXLink", title: "Orb Executor, Created by Another Thread, Unread Messages\nFixture", url: ampURL)), true)
    }

    func testGeminiKeepsDuplicateRowsSeparateAndSkipsNotebooks()
 {
        let sidebar = SidebarNode("sidebar", role: "AXList", title: "사이드바", children: [
            SidebarNode("library", role: "AXRow", title: "라이브러리"),
            SidebarNode("notebook", role: "AXRow", title: "Notebook"),
            SidebarNode("all", role: "AXRow", detail: "전체", value: "펼침"),
            SidebarNode("a", role: "AXRow", title: "Same title"),
            SidebarNode("b", role: "AXRow", title: "Same title", selected: true)
        ])
        let rows = ThreadExtractor.extract(app: .gemini, sidebar: sidebar, generation: "g1")
        XCTAssertEqual(rows.map(\.title), ["Same title", "Same title"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertNotEqual(rows.first?.id, ThreadExtractor.extract(app: .gemini, sidebar: sidebar, generation: "g2").first?.id)
        XCTAssertTrue(ThreadExtractor.extract(app: .gemini, sidebar: SidebarNode("root", children: [SidebarNode("a", role: "AXRow", title: "Unknown section")]), generation: "g").isEmpty)
    }

    func testUnreadRequiresExplicitClearingAndDoesNotBecomeCompletion() {
        var memory = NativeUnreadMemory()
        memory.update(["a": .unread], visibleIDs: ["a", "b"])
        memory.update([:], visibleIDs: ["a", "b"])
        XCTAssertEqual(memory.value("a"), true)
        XCTAssertNil(memory.value("b"))
        memory.update(["a": .unknown], visibleIDs: ["a"])
        XCTAssertEqual(memory.value("a"), false)
        memory.update(["a": .unread], visibleIDs: ["a"])
        memory.update([:], visibleIDs: [])
        XCTAssertNil(memory.value("a"))
        var value = session(.amp); value.sourceUnread = true
        let registry = AgentSessionRegistry(); registry.replace([value])
        XCTAssertEqual(registry.findSession(value.id)?.state, .unknown)
        XCTAssertFalse(registry.findSession(value.id)!.hasUnreadCompletion)
        XCTAssertNotEqual(value.displayStateName, "Completed")
        value.state = .working
        XCTAssertEqual(value.displayState, .working)
        XCTAssertEqual(value.sourceUnread, true)
    }

    func testAmpAndGeminiRoutesStayInTheirOwnDesktopApp() {
        for (type, app, explicit) in [(AgentType.amp, AgentApp.amp, ConversationTarget.ampDesktop), (.gemini, .gemini, .geminiDesktop)] {
            let value = session(type)
            let expected: [ConversationRoute] = [.nativeSidebar(app, "fixture", 42)]
            XCTAssertEqual(ConversationRoutePolicy.routes(for: value, preference: .automatic, runningBundles: Set(app.bundleIDs), pathExists: { _ in false }), expected)
            XCTAssertEqual(ConversationRoutePolicy.routes(for: value, preference: explicit, runningBundles: [], pathExists: { _ in false }), expected)
            XCTAssertTrue(ConversationRoutePolicy.routes(for: value, preference: .visualStudioCode, runningBundles: Set(app.bundleIDs), pathExists: { _ in false }).isEmpty)
            XCTAssertTrue(ConversationRoutePolicy.routes(for: value, preference: .automatic, runningBundles: [], pathExists: { _ in false }).isEmpty)
        }
    }

    func testOldSavedCompletionStillLoadsWithoutNewUnreadField() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-schema-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        var value = session(.codex); value.nativeThreadID = nil; value.state = .completed
        value.hasUnreadCompletion = true; value.completionRevision = "revision"
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        encoded.removeValue(forKey: "sourceUnread")
        try JSONSerialization.data(withJSONObject: ["acknowledged": [:], "pending": [value.id: encoded]]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let restored = AgentSessionRegistry(storageURL: file).findSession(value.id)
        XCTAssertTrue(restored?.hasUnreadCompletion == true)
        XCTAssertNil(restored?.sourceUnread)
    }

    func testUnreadSortsAheadOfIdleAndWindowSignalHasNoThreadRoute() {
        var unread = session(.amp); unread.sourceUnread = true
        var idle = session(.gemini); idle.lastActivityAt = Date()
        let registry = AgentSessionRegistry(); registry.replace([idle, unread])
        XCTAssertEqual(registry.getAllAgents().first?.id, unread.id)
        var window = session(.gemini); window.statusSource = "desktop-window"; window.state = .working
        XCTAssertTrue(window.isAppActivity)
        XCTAssertTrue(ConversationRoutePolicy.routes(for: window, preference: .automatic,
            runningBundles: Set(AgentApp.gemini.bundleIDs), pathExists: { _ in false }).isEmpty)
    }
func testAmpReviewRetainsReadRowWithoutManufacturingActivity() {
    var now = Date(timeIntervalSince1970: 10_000)
    let registry = AgentSessionRegistry(timeProvider: { now })
    var value = session(.amp); value.sourceUnread = true
    registry.replace([value])
    registry.recordNavigation(value.id, result: .nativeSelectionAccepted)
    XCTAssertEqual(registry.findSession(value.id)?.sourceUnread, true) // Only source clears its dot.
    value.sourceUnread = false
    registry.replace([value])
    let viewed = registry.findSession(value.id)!
    XCTAssertEqual(viewed.lastViewedAt, now)
    XCTAssertNil(viewed.nativeActivityAt)
    XCTAssertEqual(viewed.lastActivityAt, value.lastActivityAt)
    XCTAssertFalse(viewed.hasUnreadCompletion)
    XCTAssertEqual(SessionListPolicy.rows([viewed], now: now).map(\.id), [value.id])
    now = now.addingTimeInterval(1800); registry.replace([value])
    XCTAssertEqual(registry.findSession(value.id)?.lastViewedAt, viewed.lastViewedAt)
    XCTAssertEqual(SessionListPolicy.rows(registry.getAllAgents(), now: now).count, 1)
    XCTAssertTrue(SessionListPolicy.rows(registry.getAllAgents(), hidden: [value.id], now: now).isEmpty)
    now = now.addingTimeInterval(1801); registry.replace([value])
    XCTAssertTrue(SessionListPolicy.rows(registry.getAllAgents(), now: now).isEmpty)
    XCTAssertEqual(registry.findSession(value.id)?.lastViewedAt, viewed.lastViewedAt)
}

func testAmpSourceReadTransitionRetainsButInitialReadAndFailedNavigationDoNot() {
    let now = Date(timeIntervalSince1970: 10_000)
    let registry = AgentSessionRegistry(timeProvider: { now })
    var value = session(.amp); value.sourceUnread = false; value.nativeSelected = true
    registry.replace([value])
    for result in [ConversationOpenResult.failed, .projectOnly, .extensionRequested, .desktopRouteAccepted] {
        registry.recordNavigation(value.id, result: result)
        XCTAssertNil(registry.findSession(value.id)?.lastViewedAt)
    }
    XCTAssertTrue(SessionListPolicy.rows(registry.getAllAgents(), now: now).isEmpty)
    value.sourceUnread = true; registry.replace([value])
    value.sourceUnread = false; registry.replace([value])
    XCTAssertEqual(registry.findSession(value.id)?.lastViewedAt, now)
    XCTAssertEqual(SessionListPolicy.rows(registry.getAllAgents(), now: now).count, 1)
    var other = session(.gemini); other.sourceUnread = true
    registry.replace([other]); other.sourceUnread = false; registry.replace([other])
    registry.recordNavigation(other.id, result: .nativeSelectionAccepted)
    XCTAssertNil(registry.findSession(other.id)?.lastViewedAt)
}

func testAmpReviewPersistsTimestampButNeverResurrectsMissingNativeRow() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-review-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("state.json")
    let now = Date(timeIntervalSince1970: 10_000)
    let registry = AgentSessionRegistry(timeProvider: { now }, storageURL: file)
    var value = session(.amp); value.sourceUnread = false
    registry.replace([value]); registry.recordNavigation(value.id, result: .nativeSelectionAccepted)
    let restored = AgentSessionRegistry(timeProvider: { now.addingTimeInterval(30) }, storageURL: file)
    XCTAssertTrue(restored.getAllAgents().isEmpty)
    restored.replace([value])
    XCTAssertEqual(restored.findSession(value.id)?.lastViewedAt, now)
    XCTAssertEqual(SessionListPolicy.rows(restored.getAllAgents(), now: now.addingTimeInterval(30)).count, 1)
    restored.replace([]); XCTAssertTrue(restored.getAllAgents().isEmpty)
    let reversed = AgentSessionRegistry(timeProvider: { now.addingTimeInterval(-1) }, storageURL: file)
    reversed.replace([value]); XCTAssertNil(reversed.findSession(value.id)?.lastViewedAt)
}

}

extension NativeSidebarProviderTests {
    func testExistingGeminiReplyDoesNotInventUnreadOrCarryItAcrossTurns() throws {
        let registry = AgentSessionRegistry(storageURL: nil)
        var row = session(.gemini)
        row.nativeThreadID = nil
        row.currentTurnID = "first"
        row.state = .completed
        row.completionRevision = "first-reply"
        row.completionIsBaseline = true
        registry.replace([row])
        XCTAssertFalse(try XCTUnwrap(registry.findSession(row.id)).hasUnreadCompletion)
        row.completionIsBaseline = false
        registry.replace([row])
        XCTAssertTrue(try XCTUnwrap(registry.findSession(row.id)).hasUnreadCompletion)
        row.state = .unknown
        row.completionRevision = nil
        row.currentTurnID = "second"
        registry.replace([row])
        XCTAssertFalse(try XCTUnwrap(registry.findSession(row.id)).hasUnreadCompletion)
    }

    func testAmpStableReadRevisionSurvivesRestartWithoutRetainingNativeRoute() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        let registry = AgentSessionRegistry(storageURL: file)
        var row = AgentSession(id: "desktop:amp:" + ampURL, agentType: .amp, state: .completed,
            hasUnreadCompletion: false, completionDetectedAt: nil, startedAt: Date(), lastActivityAt: Date(),
            isActive: false, hasBackgroundTasks: false, tokens5h: 0, tokensWeek: 0)
        row.nativeThreadID = "amp:" + ampURL
        row.completionRevision = "amp-end:1"
        registry.replace([row])
        registry.acknowledgeCompletion(row.id, revision: row.completionRevision)
        let relaunched = AgentSessionRegistry(storageURL: file)
        XCTAssertNil(relaunched.findSession(row.id))
        relaunched.replace([row])
        XCTAssertFalse(try XCTUnwrap(relaunched.findSession(row.id)).hasUnreadCompletion)
    }
}
