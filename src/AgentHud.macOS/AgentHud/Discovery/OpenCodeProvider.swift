import Foundation

/// Discovers OpenCode V2 conversations from its local SQLite database. Current V2
/// sessions live in `session_v2` (the older `session` table is retained for legacy
/// data), and all providers share that table.
public final class OpenCodeProvider: IAgentProvider {
    public let agentType: AgentType = .openCode
    public let watchRoots: [String]

    private let retainedParentIDs: () -> [String]
    private let databasePath: String
    private var activeWindow: TimeInterval

    private struct DatabaseSession: Decodable {
        let id: String
        let parent_id: String?
        let directory: String
        let title: String?
        let time_created: Int64
        let time_updated: Int64
        let model: String?
        let cost: Double?
        let tokens_input: Int64?
        let tokens_output: Int64?
        let tokens_reasoning: Int64?
        let tokens_cache_read: Int64?
        let tokens_cache_write: Int64?
        let time_archived: Int64?
    }

    public init(home: String, activeWindow: TimeInterval = 60 * 60, retainedParentIDs: @escaping () -> [String] = { [] }) {
        self.retainedParentIDs = retainedParentIDs
        let root = home + "/.local/share/opencode"
        self.watchRoots = [root]
        self.databasePath = root + "/opencode.db"
        self.activeWindow = activeWindow
    }

    public func setActiveWindow(_ value: TimeInterval) {
        activeWindow = max(60, value)
    }

    public func discover() async throws -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
        let data = try runSQLite()
        guard !data.isEmpty else { return [] }
        let sessions = try JSONDecoder().decode([DatabaseSession].self, from: data)
        let now = Date()
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Set(sessions.filter { now.timeIntervalSince1970 - Double($0.time_updated) / 1000 <= activeWindow }.map(\.id))
        included.formUnion(retainedParentIDs().filter { $0.hasPrefix("opencode:") }.map { String($0.dropFirst(9)) })
        var pending = Array(included)
        while let id = pending.popLast() {
            guard let row = byID[id] else { continue }
            if let parent = row.parent_id, byID[parent] != nil, included.insert(parent).inserted { pending.append(parent) }
        }
        return sessions.compactMap { row in

            guard !row.directory.isEmpty else { return nil }
            let created = Date(timeIntervalSince1970: TimeInterval(row.time_created) / 1000)
            let updated = Date(timeIntervalSince1970: TimeInterval(row.time_updated) / 1000)
            let active = now.timeIntervalSince(updated) <= activeWindow
            // The HUD lists current conversations, not the entire historical DB.
            // A session becomes visible again as soon as OpenCode updates it.
            guard included.contains(row.id) else { return nil }
            let state: AgentState = .unknown // Archival is not evidence of execution or completion.
            var session = AgentSession(
                id: "opencode:\(row.id)", agentType: .openCode, state: state,
                hasUnreadCompletion: false, completionDetectedAt: nil, processId: nil,
                projectPath: row.directory, worktreePath: nil,
                sessionTitle: row.title.flatMap { $0.isEmpty ? nil : $0 } ?? row.model,
                currentTask: nil, startedAt: created, lastActivityAt: updated,
                isActive: active, wakeupAt: nil, hasBackgroundTasks: false,
                parentSessionId: row.parent_id.flatMap { ActivityFileStore.validSessionID($0, app: .openCode) && $0 != row.id ? "opencode:\($0)" : nil }, rateLimitResetAt: nil,
                tokens5h: (row.tokens_input ?? 0) + (row.tokens_output ?? 0),
                tokensWeek: (row.tokens_input ?? 0) + (row.tokens_output ?? 0),
                primaryLimit: nil, secondaryLimit: nil, limitsUpdatedAt: nil
            )
            session.isSubagent = row.parent_id != nil
            session.isAncestorContext = !active
            return session
        }
    }

    private func runSQLite() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let retained = retainedParentIDs().filter { $0.hasPrefix("opencode:") }.map { String($0.dropFirst(9)) }
            .filter { ActivityFileStore.validSessionID($0, app: .openCode) }.prefix(100)
        let ids = retained.isEmpty ? "NULL" : retained.map { "'\($0)'" }.joined(separator: ",")
        process.arguments = [

            "-readonly", "-json", databasePath,
            "WITH RECURSIVE roots(id) AS (SELECT id FROM (SELECT id FROM session_v2 ORDER BY time_updated DESC LIMIT 100) " +
            "UNION SELECT id FROM session_v2 WHERE id IN (\(ids))), family(id) AS (SELECT id FROM roots UNION " +
            "SELECT s.parent_id FROM session_v2 s JOIN family f ON s.id=f.id WHERE s.parent_id IS NOT NULL) " +
            "SELECT id, parent_id, directory, title, time_created, time_updated, model, cost, " +
            "tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, " +
            "tokens_cache_write, time_archived FROM session_v2 " +
            "WHERE id IN (SELECT id FROM family LIMIT 300) ORDER BY time_updated DESC;"
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "OpenCodeProvider", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(
                            decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
        }
        return data
    }
}
