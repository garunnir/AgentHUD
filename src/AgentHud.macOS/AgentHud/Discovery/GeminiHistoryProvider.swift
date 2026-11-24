import AppKit
import Foundation
import Darwin

public struct GeminiConversationReference: Codable, Equatable, Sendable {
    let profile: String
    let databaseID: String
    let chatID: String
    var isValid: Bool {
        profile.range(of: #"^user[0-9]+$"#, options: .regularExpression) != nil && UUID(uuidString: databaseID) != nil
            && chatID.range(of: #"^c_[0-9a-f]{16}$"#, options: .regularExpression) != nil
    }
    static func documentID(_ url: URL) -> String? {
        guard url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, url.query == nil else { return nil }
        let parts = url.pathComponents
        guard url.scheme == "googlegemini", url.host == "conversation", parts.count == 2 else { return nil }
        let id = parts[1]
        return id.range(of: #"^c_[0-9a-f]{16}$"#, options: .regularExpression) != nil ? id : nil
    }
    var sessionKey: String { "gemini:\(profile):\(databaseID):\(chatID)" }
    var url: URL? { isValid ? URL(string: "googlegemini://conversation/\(chatID)") : nil }
}

/// Gemini 1.144.7.1478 cache schema. Reads IDs/message timestamps only, never encrypted protos or credentials.
struct GeminiHistoryStore {
    struct Row: Decodable {
        let chat_id: String
        let database_id: String
        let server_id: String?
        let turn_id: String?
        let latest_message: String?
        let reply_pk: Int?
        let reply_id: String?
        let reply_turn: String?
        let reply_bytes: Int?
        let reply_created: Double?
        let message_at: Double
    }
    struct Entry {
        let reference: GeminiConversationReference
        let serverID: String?
        let messageAt: Date
        var turnID: String? = nil
        var latestMessage: String? = nil
        var reply: GeminiReplyTracker.Reply? = nil
        var replyTurn: String? = nil
    }
    let root: URL
    static func defaultRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/com.google.GeminiMacOS/Gemini")
    }
    func singleProfile() -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        let profiles = children.filter { $0.lastPathComponent.range(of: #"^user[0-9]+$"#, options: .regularExpression) != nil }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ChatInfo2.store").path) }
        // No active-account inference across multiple profiles. Changing/replacing a store changes its database UUID.
        return profiles.count == 1 ? profiles[0] : nil
    }
    static func messageDate(_ cocoaSeconds: Double, now: Date) -> Date? {
        guard cocoaSeconds.isFinite, cocoaSeconds >= 0 else { return nil }
        let date = Date(timeIntervalSinceReferenceDate: cocoaSeconds)
        return date <= now ? date : nil
    }
    func read(now: Date) throws -> [Entry] {
        guard let profile = singleProfile() else { return [] }
        let statement = "SELECT c.ZCHATUUID AS chat_id,c.ZROBINCONVERSATIONID AS server_id,(SELECT Z_UUID FROM Z_METADATA LIMIT 1) AS database_id," +
            "MAX(m.ZCREATEDTIME) AS message_at FROM ZCHATINFOSTOREDMODEL c JOIN ZCHATMESSAGESTOREDMODEL m ON m.ZCHATUUID=c.ZCHATUUID " +
            "WHERE m.ZCREATEDTIME IS NOT NULL GROUP BY c.ZCHATUUID ORDER BY message_at DESC LIMIT 300;"
        let lastTurn = "(SELECT u.ZMESSAGEUUID FROM ZCHATMESSAGESTOREDMODEL u WHERE u.ZCHATUUID=c.ZCHATUUID AND u.ZISUSERTURN=1 ORDER BY u.ZMESSAGEINDEX DESC LIMIT 1) AS turn_id,"
        let lastMessage = "(SELECT m2.ZMESSAGEUUID FROM ZCHATMESSAGESTOREDMODEL m2 WHERE m2.ZCHATUUID=c.ZCHATUUID ORDER BY m2.ZMESSAGEINDEX DESC LIMIT 1) AS latest_message,"
        let turns = statement.replacingOccurrences(of: "MAX(m.ZCREATEDTIME)", with: lastTurn + lastMessage + "MAX(m.ZCREATEDTIME)")
        let replyUser = "(SELECT u.ZMESSAGEUUID FROM ZCHATMESSAGESTOREDMODEL u WHERE u.ZCHATUUID=c.ZCHATUUID " +
            "AND u.ZISUSERTURN=1 AND u.ZMESSAGEINDEX=a.ZMESSAGEINDEX-1 LIMIT 1) AS reply_turn,"
        let replyFields = replyUser + "a.Z_PK AS reply_pk,a.ZMESSAGEUUID AS reply_id,a.ZBYTESIZE AS reply_bytes,a.ZCREATEDTIME AS reply_created,"
        let join = "LEFT JOIN ZCHATMESSAGESTOREDMODEL a ON a.Z_PK=(SELECT x.Z_PK FROM ZCHATMESSAGESTOREDMODEL x " +
            "WHERE x.ZCHATUUID=c.ZCHATUUID AND x.ZISUSERTURN=0 ORDER BY x.ZCREATEDTIME DESC,x.Z_PK DESC LIMIT 1) "
        let streaming = turns.replacingOccurrences(of: "MAX(m.ZCREATEDTIME)", with: replyFields + "MAX(m.ZCREATEDTIME)")
            .replacingOccurrences(of: "WHERE m.ZCREATEDTIME", with: join + "WHERE m.ZCREATEDTIME")
        var data = try query(profile: profile, sql: streaming)
        if data.isEmpty { data = try query(profile: profile, sql: turns) }
        if data.isEmpty { data = try query(profile: profile, sql: statement) }
        if data.isEmpty {
            // Older stores still supply local dates and desktop routes.
            data = try query(profile: profile, sql: statement.replacingOccurrences(of: "c.ZROBINCONVERSATIONID AS server_id", with: "NULL AS server_id"))
        }
        guard !data.isEmpty else { return [] }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.compactMap { row in
            let reference = GeminiConversationReference(profile: profile.lastPathComponent, databaseID: row.database_id, chatID: row.chat_id)
            guard reference.isValid, let date = Self.messageDate(row.message_at, now: now) else { return nil }
            var entry = Entry(reference: reference, serverID: row.server_id, messageAt: date, turnID: row.turn_id, latestMessage: row.latest_message)
            if let pk = row.reply_pk, let bytes = row.reply_bytes, let created = row.reply_created,
               let date = Self.messageDate(created, now: now) {
                entry.replyTurn = row.reply_turn
                entry.reply = .init(pk: pk, id: row.reply_id, bytes: bytes, created: date)
            }
            return entry
        }
    }
    func contains(_ reference: GeminiConversationReference, serverID: String? = nil) -> Bool {
        if let serverID, serverID.range(of: #"^c_[0-9a-f]{16}$"#, options: .regularExpression) == nil { return false }
        let bridge = serverID.map { " AND ZROBINCONVERSATIONID='\($0)' AND (SELECT COUNT(*) FROM ZCHATINFOSTOREDMODEL WHERE ZROBINCONVERSATIONID='\($0)')=1" } ?? ""
        guard reference.isValid, let profile = singleProfile(), profile.lastPathComponent == reference.profile,
              let data = try? query(profile: profile, sql: "SELECT COUNT(*) FROM ZCHATINFOSTOREDMODEL WHERE ZCHATUUID='\(reference.chatID)'\(bridge) AND EXISTS (SELECT 1 FROM Z_METADATA WHERE Z_UUID='\(reference.databaseID)');", json: false) else { return false }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
    private func query(profile: URL, sql: String, json: Bool = true) throws -> Data {
        let database = profile.appendingPathComponent("ChatInfo2.store")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: database.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.ownerAccountID] as? UInt32 == getuid() else { return Data() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly"] + (json ? ["-json"] : []) + ["-cmd", ".timeout 300", database.path, sql]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, data.count < 1_048_576 else { return Data() }
        return data
    }
}

// The desktop streams a reply into one Core Data row. Its primary key stays stable
// when Gemini replaces its provisional message ID with the server's candidate ID.
struct GeminiReplyTracker {
    struct Reply {
        let pk: Int
        let id: String?
        let bytes: Int
        let created: Date
    }

    private var reply: Reply?
    private var lastTurn: String?
    private var precedingTurn: String?
    private var startedHere = false
    private var finished = false
    private var lastProgress: Date?

    mutating func observe(_ next: Reply?, turn: String?, nativeStop: Bool, now: Date) {
        guard let next else { return }
        let changed = next.pk != reply?.pk
        let grew = !changed && next.bytes > (reply?.bytes ?? next.bytes)
        if changed {
            precedingTurn = lastTurn
            lastTurn = nil
            startedHere = reply != nil
            lastProgress = nil
            finished = false
        }
        // Baseline rows can be synchronized when a conversation opens. Require a
        // live Stop control or growth on a newly observed reply before starting.
        let age = now.timeIntervalSince(next.created)
        if !finished, age >= 0, (age < 120 || isRunning(at: now)),
           (startedHere && (nativeStop || grew) || nativeStop && grew) {
            lastProgress = now
            startedHere = true
        }
        reply = next
        if let turn { lastTurn = turn }
    }

    func isRunning(at now: Date) -> Bool {
        lastProgress.map { now.timeIntervalSince($0) < 90 } ?? false
    }

    func acceptsCompletion(turn: String, candidate: String) -> Bool {
        guard let reply else { return true } // Older desktop caches omit row metadata.
        return reply.id == candidate && (!startedHere || precedingTurn != turn)
    }

    mutating func finish() { finished = true; lastProgress = nil }
}

final class GeminiHistoryProvider: IAgentProvider {
    let agentType: AgentType = .gemini
    var watchRoots: [String] { [store.root.path] }
    private let native: NativeSidebarClient
    private let store: GeminiHistoryStore
    private let poller = DesktopThreadPoller(.gemini)
    private var observedTurns: [String: (id: String, beganHere: Bool)] = [:]
    private var trackers: [String: GeminiReplyTracker] = [:]
    private var trustedPID: pid_t?
    private var firstSnapshotAt: Date?
    private var lastWebScan = Date.distantPast
    init(home: String, native: NativeSidebarClient) { self.native = native; store = GeminiHistoryStore(root: GeminiHistoryStore.defaultRoot(home: home)) }
    func discover() async throws -> [AgentSession] {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.GeminiMacOS").first,
              !process.isTerminated, AXIsProcessTrusted() else {
            trustedPID = nil; trackers.removeAll(); observedTurns.removeAll(); firstSnapshotAt = nil
            return []
        }
        if trustedPID != process.processIdentifier {
            trackers.removeAll(); observedTurns.removeAll(); firstSnapshotAt = nil
        }
        let now = Date()
        let live = await native.hasLiveSidebar(app: .gemini, pid: process.processIdentifier)
        let entries = (try? store.read(now: now)) ?? []
        let busy = await native.geminiResponseWindows(pid: process.processIdentifier)
        if live { trustedPID = process.processIdentifier }
        let trusted = trustedPID == process.processIdentifier
        let attributed = trusted ? Set(entries.map { $0.reference.chatID }).intersection(busy.ids) : []
        let titles = GeminiTitles.saved
        let byTitle = Dictionary(grouping: entries, by: { titles[$0.reference.sessionKey] ?? "" })
        let windowTitles = Set(busy.unidentifiedWindowTitles.compactMap { $0 }.filter { !$0.isEmpty })
        var boundTitles = Set<String>()
        if trusted, !entries.isEmpty {
            let keys = Set(entries.map { $0.reference.sessionKey })
            trackers = trackers.filter { keys.contains($0.key) }
            for entry in entries {
                let key = entry.reference.sessionKey
                let title = titles[key] ?? ""
                let matchingWindow = windowTitles.contains(title) && byTitle[title]?.count == 1
                trackers[key, default: GeminiReplyTracker()].observe(entry.reply, turn: entry.replyTurn,
                    nativeStop: matchingWindow || attributed.contains(entry.reference.chatID), now: now)
                if matchingWindow, trackers[key]?.isRunning(at: now) == true { boundTitles.insert(title) }
            }
        }
        var windowRows: [AgentSession] = []
        if busy.unidentifiedWindowTitles.contains(where: { !boundTitles.contains($0 ?? "") }) || !busy.ids.isSubset(of: attributed) {
            var window = AgentSession(id: "appactivity:gemini:\(process.processIdentifier)", agentType: .gemini,
                state: .working, hasUnreadCompletion: false, completionDetectedAt: nil, processId: Int(process.processIdentifier),
                projectPath: nil, worktreePath: nil, sessionTitle: Localiz.current.string("State.CurrentWindowWorking"),
                currentTask: nil, startedAt: now, lastActivityAt: now, isActive: true, wakeupAt: nil, hasBackgroundTasks: false,
                parentSessionId: nil, rateLimitResetAt: nil, tokens5h: 0, tokensWeek: 0, primaryLimit: nil, secondaryLimit: nil)
            window.statusSource = "desktop-window"
            windowRows.append(window)
        }
        guard trusted else { return windowRows }
        let documents = await native.geminiDocumentTitles(pid: process.processIdentifier)
        for entry in entries {
            if let title = documents[entry.reference.chatID] { await GeminiTitles.record(title, for: entry.reference) }
        }
        let minutes = UserDefaults.standard.object(forKey: "hud.activeWindowMinutes") as? Int ?? 60
        let recent = entries.filter { now.timeIntervalSince($0.messageAt) <= Double(max(1, minutes)) * 60 }
        let serverIDs = Set(recent.compactMap(\.serverID).filter { $0.range(of: #"^c_[0-9a-f]{16}$"#, options: .regularExpression) != nil })
        if !serverIDs.isEmpty, now.timeIntervalSince(lastWebScan) >= 30 {
            lastWebScan = now
            let saved = GeminiTitles.saved
            let web = GeminiWebList.titles(for: serverIDs)
            await GeminiBackgroundTitles.shared.refresh(recent, store: store, now: now)
            let mappings = Dictionary(grouping: entries.compactMap { entry in entry.serverID.map { ($0,entry.reference) } }, by: { $0.0 })
            for (id,title) in web {
                if let refs = mappings[id], refs.count == 1, saved[refs[0].1.sessionKey] != title,
                   store.contains(refs[0].1, serverID: id) {
                    await GeminiTitles.record(title, for: refs[0].1)
                }
            }
        }
        let unique = Dictionary(grouping: entries, by: { $0.serverID ?? "" })
        let requests = recent.reduce(into: [String: String]()) { result, entry in
            guard let id = entry.serverID, unique[id]?.count == 1, serverIDs.contains(id),
                  let turn = entry.turnID, turn.range(of: #"^r_[0-9a-f]{16}$"#, options: .regularExpression) != nil else { return }
            result[id] = turn
        }
        let eligible = Set(entries.map { $0.reference.sessionKey })
        let baseline = firstSnapshotAt
        if !entries.isEmpty, firstSnapshotAt == nil { firstSnapshotAt = now }
        observedTurns = observedTurns.filter { eligible.contains($0.key) }
        let reports = await poller.sample(requests, now: now)

        return windowRows + entries.map { entry in

            let ref = entry.reference
            let date = entry.messageAt.formatted(date: .numeric, time: .shortened)
            var session = AgentSession(id: ref.sessionKey, agentType: .gemini,
                state: .unknown, hasUnreadCompletion: false, completionDetectedAt: nil, processId: Int(process.processIdentifier),
                projectPath: nil, worktreePath: nil, sessionTitle: titles[ref.sessionKey] ?? (Localiz.current.string("Session.DatedChat") + " · " + date),
                currentTask: nil, startedAt: entry.messageAt, lastActivityAt: entry.messageAt, isActive: false,
                wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: nil, rateLimitResetAt: nil,
                tokens5h: 0, tokensWeek: 0, primaryLimit: nil, secondaryLimit: nil)
            session.currentTurnID = entry.turnID
            session.geminiConversation = ref; session.statusSource = "desktop-message-date"
            let streaming = trackers[ref.sessionKey]?.isRunning(at: now) == true
            let report = entry.serverID.flatMap { reports[$0] }
            let finished = report?.state == .completed && report?.turn == entry.turnID
                && entry.turnID != nil && entry.latestMessage?.range(of: #"^rc_[0-9a-f]{16}$"#, options: .regularExpression) != nil
                && (entry.reply == nil || entry.replyTurn == entry.turnID)
                && (trackers[ref.sessionKey]?.acceptsCompletion(turn: entry.turnID ?? "", candidate: entry.latestMessage ?? "") ?? true)
            if let turn = entry.turnID {
                let previous = observedTurns[ref.sessionKey]
                let running = streaming || attributed.contains(ref.chatID) || report?.state == .working
                let began = running || (previous.map { $0.id != turn || $0.beganHere }
                    ?? baseline.map { entry.messageAt > $0 } ?? false)
                observedTurns[ref.sessionKey] = (turn, began)
            }
            if attributed.contains(ref.chatID) || (streaming && !finished) {
                session.state = .working
                session.isActive = true
                session.statusSource = streaming ? "gemini-stream" : "gemini-document"
            } else if let id = entry.serverID, let turn = requests[id], let report = reports[id], report.turn == turn,
               report.state == .working || finished {
                session.state = report.state
                session.isActive = report.state == .working
                session.statusSource = "gemini-turn"
                if report.state == .completed, let candidate = entry.latestMessage {
                    trackers[ref.sessionKey]?.finish()
                    session.completionRevision = "gemini-end:\(turn):\(candidate)"
                    session.completionIsBaseline = observedTurns[ref.sessionKey]?.beganHere != true
                }
            }
            return session
        }
    }
}

enum GeminiTitles {
    private static let defaultsKey = "GeminiConversationTitles.v1"
    static var saved: [String: String] { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }

    @MainActor static func record(_ title: String, for reference: GeminiConversationReference) {
        guard reference.isValid, !title.isEmpty, title.count <= 512 else { return }
        var values = saved
        guard values[reference.sessionKey] != title else { return }
        values[reference.sessionKey] = title
        UserDefaults.standard.set(values, forKey: defaultsKey)
    }
}
