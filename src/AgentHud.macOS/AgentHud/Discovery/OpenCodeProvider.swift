import Foundation

/// Discovers OpenCode V2 conversations from its local SQLite database. Current V2
/// sessions live in `session_v2` (the older `session` table is retained for legacy
/// data), and all providers share that table.
public final class OpenCodeProvider: IAgentProvider {
    public let agentType: AgentType = .openCode
    public let watchRoots: [String]

    private let databasePath: String
    private var activeWindow: TimeInterval

    private struct DatabaseSession: Decodable {
        let id: String
        let directory: String
        let title: String
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

    public init(home: String, activeWindow: TimeInterval = 60 * 60) {
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
        let sessions = try JSONDecoder().decode([DatabaseSession].self, from: data)
        let now = Date()
        return sessions.compactMap { row in
            guard !row.directory.isEmpty else { return nil }
            let created = Date(timeIntervalSince1970: TimeInterval(row.time_created) / 1000)
            let updated = Date(timeIntervalSince1970: TimeInterval(row.time_updated) / 1000)
            let active = now.timeIntervalSince(updated) <= activeWindow
            // The HUD lists current conversations, not the entire historical DB.
            // A session becomes visible again as soon as OpenCode updates it.
            guard active else { return nil }
            let state: AgentState = row.time_archived == nil ? .working : .completed
            return AgentSession(
                id: "opencode:\(row.id)", agentType: .openCode, state: state,
                hasUnreadCompletion: false, completionDetectedAt: nil, processId: nil,
                projectPath: row.directory, worktreePath: nil,
                sessionTitle: row.title.isEmpty ? row.model : row.title,
                currentTask: nil, startedAt: created, lastActivityAt: updated,
                isActive: active, wakeupAt: nil, hasBackgroundTasks: false,
                parentSessionId: nil, rateLimitResetAt: nil,
                tokens5h: (row.tokens_input ?? 0) + (row.tokens_output ?? 0),
                tokensWeek: (row.tokens_input ?? 0) + (row.tokens_output ?? 0),
                primaryLimit: nil, secondaryLimit: nil, limitsUpdatedAt: nil
            )
        }
    }

    private func runSQLite() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-json", databasePath,
            "SELECT id, directory, title, time_created, time_updated, model, cost, " +
            "tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, " +
            "tokens_cache_write, time_archived FROM session_v2 " +
            "ORDER BY time_updated DESC LIMIT 100;"
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
