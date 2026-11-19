import XCTest
@testable import AgentHud

final class AmpUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1794988800)
    private func parse(_ tokens: [String]) -> AmpUsage? {
        AmpUsagePage.parse(tokens, now: now, zone: TimeZone(identifier: "Asia/Seoul")!)
    }

    func testKeepsBothAllowancesAndSharedLocalizedReset() throws {
        let usage = try XCTUnwrap(parse(["Agent Usage", ">99.5%", "remaining", "Orb Usage", "42.3%", "remaining",
            "Agent and orb usage resets 2026년 12월 18일 오전 8:28"]))
        XCTAssertEqual(usage.agent.label, ">99.5%")
        XCTAssertFalse(usage.agent.indicatesLowBalance(at: 99.5))
        XCTAssertTrue(usage.orb.indicatesLowBalance(at: 42.3))
        XCTAssertEqual(usage.orb.value, 42.3)
        XCTAssertEqual(usage.reset, ISO8601DateFormatter().date(from: "2026-12-17T23:28:00Z"))
    }

    func testRequiresDistinctLabelsValidBoundsAndFutureReset() {
        let reset = "Agent and orb usage resets Dec 18, 2026, 8:28 AM"
        let tokens = ["Orb Usage", "0% remaining", "Agent Usage", "<0.5% remaining", reset]
        XCTAssertEqual(parse(tokens)?.agent.label, "<0.5%")
        XCTAssertNil(parse(["Agent Usage", "22% remaining", reset]))
        XCTAssertNil(parse(tokens + ["Orb Usage", "10% remaining"]))
        XCTAssertNil(parse(tokens.map { $0 == "0% remaining" ? "101% remaining" : $0 }))
        XCTAssertNil(parse(tokens.map { $0 == reset ? "Agent and orb usage resets Dec 18, 2025, 8:28 AM" : $0 }))
    }
}
