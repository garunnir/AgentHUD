import Foundation
import XCTest
@testable import AgentHud

final class ClaudeUsageApiTests: XCTestCase {
    func testParsesUsageResponse() throws {
        let body = #"{"five_hour":{"utilization":12.5,"resets_at":"2026-10-21T09:00:00.123456+00:00"},"seven_day":{"utilization":44,"resets_at":null},"seven_day_opus":null}"#
        let now = Date()
        let snapshot = ClaudeLimitSnapshot.parseUsageApi(Data(body.utf8), updatedAt: now)
        XCTAssertEqual(snapshot.source, .usageApi)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 12.5)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1792573200))
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 44)
        XCTAssertNil(snapshot.sevenDay?.resetsAt)
        XCTAssertFalse(ClaudeLimitSnapshot.parseUsageApi(Data(#"{"error":{}}"#.utf8), updatedAt: now).hasData)
    }

    func testPicksPlanOrganization() {
        let body = #"[{"uuid":"api-org","capabilities":["api"]},{"uuid":"chat-org","capabilities":["chat"]},{"uuid":"max-org","capabilities":["chat","claude_max"]}]"#
        XCTAssertEqual(ClaudeUsageApi.pickOrganization(Data(body.utf8)), "max-org")
        XCTAssertEqual(ClaudeUsageApi.pickOrganization(Data(#"[{"uuid":"a","capabilities":["api"]},{"uuid":"b","capabilities":["chat"]}]"#.utf8)), "b")
        XCTAssertNil(ClaudeUsageApi.pickOrganization(Data("<html>".utf8)))
    }

    func testFreshApiWinsOverStaleStatusLine() {
        let now = Date()
        let window = LimitWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(3600))
        let statusLine = ClaudeLimitSnapshot(source: .statusLine, fiveHour: window, sevenDay: window, updatedAt: now.addingTimeInterval(-15 * 3600))
        let api = ClaudeLimitSnapshot(source: .usageApi, fiveHour: window, sevenDay: window, updatedAt: now.addingTimeInterval(-60))
        let pick = ClaudeLimitPolicy.pick(statusLine: statusLine, api: api, now: now, lastClaudeActivity: now)
        XCTAssertEqual(pick.source, .usageApi)
        XCTAssertFalse(pick.fiveHourStale)
        XCTAssertFalse(pick.sevenDayStale)
    }
}
