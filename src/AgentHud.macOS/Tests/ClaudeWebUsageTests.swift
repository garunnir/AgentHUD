import XCTest
@testable import AgentHud

final class ClaudeWebUsageTests: XCTestCase {
    func testReadsWeeklyUsageIndependentlyOfProductDistribution() {
        let meters = [ClaudeUsagePage.Meter(title: "Claude Code", used: 99), .init(title: "이번 주", used: 88)]
        let sample = ClaudeUsagePage.snapshot(meters: meters, heading: true, fresh: true, now: Date())
        XCTAssertEqual(sample?.sevenDay?.usedPercent, 88)
        XCTAssertNil(sample?.fiveHour)
        XCTAssertNil(ClaudeUsagePage.snapshot(meters: meters, heading: true, fresh: false, now: Date()))
        XCTAssertNil(ClaudeUsagePage.snapshot(meters: meters, heading: false, fresh: true, now: Date()))
    }
    func testRejectsAmbiguousAndInvalidMetersAndAcceptsRealZero() {
        func result(_ values: [Double]) -> Double? {
            ClaudeUsagePage.snapshot(meters: values.map { .init(title: "This week", used: $0) },
                                     heading: true, fresh: true, now: Date())?.sevenDay?.usedPercent
        }
        XCTAssertEqual(result([0]), 0)
        XCTAssertNil(result([30,40]))
        XCTAssertNil(result([120]))
        XCTAssertNil(result([]))
    }
}

extension ClaudeWebUsageTests {
    func testWeeklyResetUsesLocalWeekdayAndClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let iso = ISO8601DateFormatter()
        let now = try XCTUnwrap(iso.date(from: "2026-11-18T08:40:00Z"))
        let friday = try XCTUnwrap(iso.date(from: "2026-11-20T01:00:00Z"))
        for text in ["(금요일) 오전 10:00에 초기화", "Resets Fri 10:00 AM", "Resets Friday at 10:00 AM"] {
            XCTAssertEqual(ClaudeUsagePage.weeklyReset(in: [text], now: now, calendar: calendar), friday)
        }
        let nextWeek = try XCTUnwrap(iso.date(from: "2026-11-27T01:00:00Z"))
        XCTAssertEqual(ClaudeUsagePage.weeklyReset(in: ["(금요일) 오전 10:00에 초기화"], now: friday, calendar: calendar), nextWeek)
        XCTAssertNil(ClaudeUsagePage.weeklyReset(in: ["주간 초기화", "Resets Fri at 15:72 PM"], now: now, calendar: calendar))
        XCTAssertNil(ClaudeUsagePage.weeklyReset(in: ["Resets Fri 10 AM", "Resets Sat 10 AM"], now: now, calendar: calendar))
    }
}

extension ClaudeWebUsageTests {
    @MainActor
    func testOffscreenSampleRequiresWeeklyResetWhenUsageIsNonzero() {
        let now = Date()
        func sample(_ used: Double, labels: [String]) -> ClaudeLimitSnapshot? {
            ClaudeWebKitUsage.sample(["heading": true, "fresh": true,
                "meters": [["title": "this week", "used": used, "labels": labels]]], now: now)
        }
        let live = sample(90, labels: ["(금요일) 오전 10:00에 초기화"])
        XCTAssertEqual(live?.sevenDay?.usedPercent, 90)
        XCTAssertNotNil(live?.sevenDay?.resetsAt)
        XCTAssertNil(live?.fiveHour)
        XCTAssertNil(sample(90, labels: []))
        let unused = sample(0, labels: [])
        XCTAssertEqual(unused?.sevenDay?.usedPercent, 0)
        XCTAssertNil(unused?.sevenDay?.resetsAt)
    }
}
