import Foundation
import XCTest
@testable import AgentHud

final class OpenCodeDiscoveryTests: XCTestCase {
    func testUntitledRowsDoNotDiscardAllSessionsAndEmptyDatabaseIsValid() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-opencode-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = root.appendingPathComponent("opencode.db")
        func sql(_ statement: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [db.path, statement]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try sql("CREATE TABLE session_v2 (id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, model TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, time_archived INTEGER);")
        let provider = OpenCodeProvider(home: home.path)
        let empty = try await provider.discover()
        XCTAssertTrue(empty.isEmpty)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try sql("INSERT INTO session_v2 (id,directory,title,time_created,time_updated) VALUES ('ses_Unnamed','/fixture',NULL,\(now),\(now)), ('ses_Named','/fixture','Fixture',\(now),\(now));")
        let sessions = try await provider.discover()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first { $0.id == "opencode:ses_Unnamed" }?.displayTitle, "Untitled")
        XCTAssertTrue(sessions.allSatisfy { $0.state == .unknown })
        try sql("UPDATE session_v2 SET parent_id='ses_Named' WHERE id='ses_Unnamed'; UPDATE session_v2 SET time_updated=1 WHERE id='ses_Named';")
        let family = try await provider.discover()
        XCTAssertEqual(family.count, 2)
        XCTAssertEqual(family.first { $0.id == "opencode:ses_Unnamed" }?.parentSessionId, "opencode:ses_Named")
        XCTAssertTrue(SessionListPolicy.rows(family).isEmpty)
        let running = family.map { value -> AgentSession in
            var value = value
            if value.id == "opencode:ses_Unnamed" { value.state = .working }
            return value
        }
        XCTAssertEqual(SessionListPolicy.rows(running).map(\.id), ["opencode:ses_Named"])
        XCTAssertTrue(SessionListPolicy.rows(running)[0].hasRunningDescendants)

    }
    func testActivityComesFromLatestMessageNotSessionTouch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-opencode-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = root.appendingPathComponent("opencode.db")
        func sql(_ statement: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [db.path, statement]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000), old = now - 3 * 86_400_000
        try sql("CREATE TABLE session_v2 (id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, model TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, time_archived INTEGER);" +
            "CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT);" +
            "INSERT INTO session_v2 (id,directory,title,time_created,time_updated) VALUES ('ses_Touched','/fixture','Old',\(old),\(now)), ('ses_Talking','/fixture','New',\(old),\(now)), ('ses_Empty','/fixture','Empty',\(now),\(now)), ('ses_EmptyOld','/fixture','EmptyOld',\(old),\(now));" +
            "INSERT INTO session_message (id,session_id,time_created,time_updated) VALUES ('m1','ses_Touched',\(old),\(old)), ('m2','ses_Talking',\(old),\(old)), ('m3','ses_Talking',\(now),\(now));")
        let sessions = try await OpenCodeProvider(home: home.path).discover()
        XCTAssertEqual(Set(sessions.map(\.id)), ["opencode:ses_Talking", "opencode:ses_Empty"])
        XCTAssertEqual(Set(SessionListPolicy.rows(sessions).map(\.id)), ["opencode:ses_Talking", "opencode:ses_Empty"])
    }
}
