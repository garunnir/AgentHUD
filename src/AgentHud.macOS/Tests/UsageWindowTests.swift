import XCTest
@testable import AgentHud

final class UsageWindowTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCodexWeeklyLimitInEitherSlot() {
        let week = LimitWindow(usedPercent: 32, resetsAt: nil, windowMinutes: 10080)
        for (first, second) in [(week, nil), (nil, week), (week, week)] as [(LimitWindow?, LimitWindow?)] {
            let windows = CodexUsage.displayWindows(primary: first, secondary: second)
            XCTAssertEqual(windows.map(\.label), ["week"])
            XCTAssertEqual(windows.map(\.window), [week])
        }
        let short = LimitWindow(usedPercent: 0, resetsAt: nil, windowMinutes: 300)
        XCTAssertEqual(CodexUsage.displayWindows(primary: short, secondary: week).map(\.label), ["5h", "week"])
    }

    func testClaudeOnlyShowsReportedUnexpiredFiveHourLimitOrExplicitBudgetWithoutData() {
        func pick(_ five: LimitWindow?, _ week: LimitWindow?) -> ClaudeLimitPick {
            ClaudeLimitPolicy.pick(statusLine: ClaudeLimitSnapshot(source: .statusLine, fiveHour: five,
                sevenDay: week, updatedAt: now), api: .none, now: now, lastClaudeActivity: nil)
        }
        let current = LimitWindow(usedPercent: 0, resetsAt: now.addingTimeInterval(18000))
        let expired = LimitWindow(usedPercent: 15, resetsAt: now.addingTimeInterval(-1))
        XCTAssertTrue(pick(current, current).showsFiveHour(at: now, tokenBudget: 0))
        XCTAssertFalse(pick(nil, current).showsFiveHour(at: now, tokenBudget: 5))
        XCTAssertFalse(pick(expired, current).showsFiveHour(at: now, tokenBudget: 0))
        XCTAssertFalse(pick(nil, nil).showsFiveHour(at: now, tokenBudget: 0))
        XCTAssertTrue(pick(nil, nil).showsFiveHour(at: now, tokenBudget: 5))
    }
}
