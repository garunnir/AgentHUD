import Foundation
import XCTest
@testable import AgentHud

final class GeminiHistoryTests: XCTestCase {
    let databaseID = "12345678-1234-1234-1234-123456789abc"
    let chat = "c_0123456789abcdef"
    func sql(_ database: URL, _ statement: String) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, statement]; process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
    func fixture(_ root: URL, profile: String = "user1") throws -> URL {
        let folder = root.appendingPathComponent(profile)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let db = folder.appendingPathComponent("ChatInfo2.store")
        try sql(db, "CREATE TABLE Z_METADATA(Z_UUID TEXT); INSERT INTO Z_METADATA VALUES ('\(databaseID)'); CREATE TABLE ZCHATINFOSTOREDMODEL(ZCHATUUID TEXT,ZROBINCONVERSATIONID TEXT,ZLASTUPDATEDTIME REAL,ZENCRYPTEDPROTOBYTES BLOB); CREATE TABLE ZCHATMESSAGESTOREDMODEL(ZCHATUUID TEXT,ZCREATEDTIME REAL,ZENCRYPTEDPROTOBYTES BLOB);")
        return db
    }
    func testOnlyMessageTimesDriveRecencyAndCanonicalRoutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Gemini-dates-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try fixture(root); let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try sql(db, "INSERT INTO ZCHATINFOSTOREDMODEL(ZCHATUUID,ZLASTUPDATEDTIME,ZENCRYPTEDPROTOBYTES) VALUES ('\(chat)',800000000,X'00'); INSERT INTO ZCHATINFOSTOREDMODEL(ZCHATUUID,ZLASTUPDATEDTIME,ZENCRYPTEDPROTOBYTES) VALUES ('c_1111111111111111',800000000,X'00'); INSERT INTO ZCHATMESSAGESTOREDMODEL VALUES ('\(chat)',799990000,X'00');")
        let store = GeminiHistoryStore(root: root)
        let old = try XCTUnwrap(store.read(now: now).first)
        XCTAssertEqual(try store.read(now: now).count, 1, "No message timestamp means no inferred date")
        XCTAssertEqual(old.messageAt, now.addingTimeInterval(-10000), "Fresh chat/cache metadata must not make an old message recent")
        XCTAssertTrue(store.contains(old.reference))
        XCTAssertEqual(old.reference.url?.absoluteString, "googlegemini://conversation/\(chat)")
        try sql(db, "UPDATE ZCHATINFOSTOREDMODEL SET ZLASTUPDATEDTIME=800000010;")
        XCTAssertEqual(try store.read(now: now).first?.messageAt, old.messageAt)
        try sql(db, "INSERT INTO ZCHATMESSAGESTOREDMODEL VALUES ('\(chat)',799999999,X'00');")
        XCTAssertEqual(try store.read(now: now).first?.messageAt, now.addingTimeInterval(-1))
        try sql(db, "UPDATE Z_METADATA SET Z_UUID='87654321-1234-1234-1234-123456789abc';")
        XCTAssertFalse(store.contains(old.reference), "Replacing the profile database invalidates old navigation")
        try sql(db, "UPDATE Z_METADATA SET Z_UUID=NULL;")
        XCTAssertTrue(try store.read(now: now).isEmpty, "Corrupt cache fails closed instead of retaining prior rows")
    }
    func testAmbiguousProfilesDisableCacheAndDatesAreValidated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Gemini-profiles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root); _ = try fixture(root, profile: "user2")
        XCTAssertNil(GeminiHistoryStore(root: root).singleProfile())
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for bad in [Double.nan, .infinity, -1, 800_000_001] { XCTAssertNil(GeminiHistoryStore.messageDate(bad, now: now)) }
        XCTAssertEqual(GeminiHistoryStore.messageDate(800_000_000, now: now), now)
        XCTAssertFalse(GeminiConversationReference(profile: "../user1", databaseID: databaseID, chatID: chat).isValid)
        XCTAssertFalse(GeminiConversationReference(profile: "user1", databaseID: databaseID, chatID: "c_bad' OR 1=1--").isValid)
    }
    func testGeminiDocumentTitleKeysRequireExactConversationRoutes() throws {
        for address in ["googlegemini://conversation/" + chat] {
            XCTAssertEqual(GeminiConversationReference.documentID(try XCTUnwrap(URL(string: address))), chat)
        }
        for address in ["https://gemini.google.com/app/0123456789abcdef", "https://example.com/app/0123456789abcdef", "googlegemini://conversation/new", "https://gemini.google.com/app/0123456789abcdef?x=y"] {
            XCTAssertNil(GeminiConversationReference.documentID(try XCTUnwrap(URL(string: address))))
        }
    }

    func testWebListMapsRemoteIDToDifferentLocalDesktopID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try fixture(root)
        try sql(db, "INSERT INTO ZCHATINFOSTOREDMODEL(ZCHATUUID,ZROBINCONVERSATIONID) VALUES ('\(chat)','c_aaaaaaaaaaaaaaaa'); INSERT INTO ZCHATMESSAGESTOREDMODEL(ZCHATUUID,ZCREATEDTIME) VALUES ('\(chat)',100);")
        let entry = try XCTUnwrap(GeminiHistoryStore(root: root).read(now: Date()).first)
        XCTAssertEqual(entry.serverID, GeminiWebList.serverID(URL(string:"https://gemini.google.com/u/1/app/aaaaaaaaaaaaaaaa")!))
        XCTAssertEqual(entry.reference.chatID, chat)
        let store = GeminiHistoryStore(root: root)
        XCTAssertTrue(store.contains(entry.reference, serverID: entry.serverID))
        try sql(db, "INSERT INTO ZCHATINFOSTOREDMODEL(ZCHATUUID,ZROBINCONVERSATIONID) VALUES ('c_bbbbbbbbbbbbbbbb','c_aaaaaaaaaaaaaaaa');")
        XCTAssertFalse(store.contains(entry.reference, serverID: entry.serverID))
        XCTAssertTrue(GeminiWebList.isHome(URL(string: GeminiWebList.address)!))
        XCTAssertNil(GeminiWebList.serverID(URL(string:"https://other.test/app/aaaaaaaaaaaaaaaa")!))
        XCTAssertFalse(GeminiWebList.isHome(URL(string:"https://gemini.google.com/app/aaaaaaaaaaaaaaaa")!))
    }

    func testGeminiDateRouteNeverUsesSidebarTitleOrVSCode() {
        let ref = GeminiConversationReference(profile: "user1", databaseID: databaseID, chatID: chat)
        var s = AgentSession(id: "gemini:fixture", agentType: .gemini, state: .unknown,
            hasUnreadCompletion: false, completionDetectedAt: nil, processId: 42, projectPath: nil,
            worktreePath: nil, sessionTitle: "Same title", currentTask: nil, startedAt: Date(), lastActivityAt: Date(),
            isActive: false, wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: nil, rateLimitResetAt: nil,
            tokens5h: 0, tokensWeek: 0, primaryLimit: nil, secondaryLimit: nil)
        s.geminiConversation = ref
        XCTAssertEqual(ConversationRoutePolicy.routes(for: s, preference: .automatic, runningBundles: ["com.google.GeminiMacOS"], pathExists: { _ in false }), [.gemini(ref)])
        XCTAssertTrue(ConversationRoutePolicy.routes(for: s, preference: .visualStudioCode, runningBundles: ["com.google.GeminiMacOS"], pathExists: { _ in false }).isEmpty)
        s.sessionTitle = "Renamed"
        XCTAssertEqual(ConversationRoutePolicy.routes(for: s, preference: .geminiDesktop, runningBundles: [], pathExists: { _ in false }), [.gemini(ref)])
    }
}

extension GeminiHistoryTests {
    func testStreamingReplySurvivesNavigationAndRejectsPreviousTurn() {
        let now = Date()
        var tracker = GeminiReplyTracker()
        func reply(_ pk: Int, _ size: Int) -> GeminiReplyTracker.Reply {
            .init(pk: pk, id: "candidate-\(pk)", bytes: size, created: now)
        }
        tracker.observe(reply(1, 200), turn: "old", nativeStop: false, now: now)
        tracker.observe(reply(2, 10), turn: "old", nativeStop: true, now: now)
        XCTAssertTrue(tracker.isRunning(at: now))
        XCTAssertFalse(tracker.acceptsCompletion(turn: "old", candidate: "candidate-2"))
        tracker.observe(reply(2, 100), turn: "new", nativeStop: false, now: now.addingTimeInterval(5))
        XCTAssertTrue(tracker.isRunning(at: now.addingTimeInterval(30)))
        XCTAssertFalse(tracker.acceptsCompletion(turn: "new", candidate: "candidate-1"))
        XCTAssertTrue(tracker.acceptsCompletion(turn: "new", candidate: "candidate-2"))
        tracker.finish()
        tracker.observe(reply(2, 200), turn: "new", nativeStop: false, now: now.addingTimeInterval(40))
        XCTAssertFalse(tracker.isRunning(at: now.addingTimeInterval(40)))
    }

    func testFreshReplyMustHaveExecutionEvidenceAndLeaseExpires() {
        let now = Date()
        var tracker = GeminiReplyTracker()
        let first = GeminiReplyTracker.Reply(pk: 1, id: "a", bytes: 100, created: now)
        tracker.observe(first, turn: "old", nativeStop: false, now: now)
        tracker.observe(.init(pk: 2, id: "b", bytes: 10, created: now), turn: "new", nativeStop: false, now: now)
        XCTAssertFalse(tracker.isRunning(at: now))
        tracker.observe(.init(pk: 2, id: "b", bytes: 500, created: now), turn: "new", nativeStop: false, now: now.addingTimeInterval(2))
        XCTAssertTrue(tracker.isRunning(at: now.addingTimeInterval(3)))
        XCTAssertFalse(tracker.isRunning(at: now.addingTimeInterval(180)))
    }
}

extension GeminiHistoryTests {
    func testUserArrivingBeforeAssistantKeepsPriorReplyPairedWithItsOwnTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try fixture(root)
        try sql(db, """
        ALTER TABLE ZCHATMESSAGESTOREDMODEL ADD COLUMN Z_PK INTEGER;
        ALTER TABLE ZCHATMESSAGESTOREDMODEL ADD COLUMN ZMESSAGEINDEX INTEGER;
        ALTER TABLE ZCHATMESSAGESTOREDMODEL ADD COLUMN ZMESSAGEUUID TEXT;
        ALTER TABLE ZCHATMESSAGESTOREDMODEL ADD COLUMN ZISUSERTURN INTEGER;
        ALTER TABLE ZCHATMESSAGESTOREDMODEL ADD COLUMN ZBYTESIZE INTEGER;
        INSERT INTO ZCHATINFOSTOREDMODEL(ZCHATUUID) VALUES ('\(chat)');
        INSERT INTO ZCHATMESSAGESTOREDMODEL(ZCHATUUID,Z_PK,ZMESSAGEINDEX,ZMESSAGEUUID,ZISUSERTURN,ZBYTESIZE,ZCREATEDTIME)
        VALUES ('\(chat)',1,0,'r_old',1,40,10),('\(chat)',2,1,'rc_old',0,60,11),('\(chat)',3,2,'r_new',1,40,12);
        """)
        let store = GeminiHistoryStore(root: root)
        let entry = try XCTUnwrap(store.read(now: Date()).first)
        XCTAssertEqual(entry.turnID, "r_new")
        XCTAssertEqual(entry.replyTurn, "r_old")
        XCTAssertEqual(entry.reply?.pk, 2)
    }
}
