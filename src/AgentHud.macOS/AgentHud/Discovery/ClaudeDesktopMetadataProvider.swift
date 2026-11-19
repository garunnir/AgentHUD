import AppKit
import Foundation
import Darwin

/// Reads Claude desktop's own canonical metadata, not anonymous sidebar rows.
final class ClaudeDesktopMetadataProvider: IAgentProvider {
    let agentType: AgentType = .claudeCode
    var watchRoots: [String] { [root.path] }
    private let root: URL
    private let client: NativeSidebarClient
    private var cache: [URL: (Date, Int64, UInt64, ClaudeDesktopLink.Metadata)] = [:]
    private var counts: [String: Int] = [:]
    private var completions: [String: (revision: String, at: Date)] = [:]
    private var pid: pid_t?
    var activeWindow: TimeInterval = 3600
    private let projects: URL
    private var savedReplies: [URL: (Date, UInt64, Int64, SavedReply?)] = [:]
    init(home: String, client: NativeSidebarClient) {
        root = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Claude/claude-code-sessions").resolvingSymlinksInPath()
        projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects").resolvingSymlinksInPath()
        self.client = client
    }
    func discover() async throws -> [AgentSession] {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first,
              !process.isTerminated else { pid = nil; counts = [:]; completions = [:]; return [] }
        if pid != process.processIdentifier { counts = [:]; completions = [:]; pid = process.processIdentifier }
        let records = readRecords()
        let activity = await client.claudeDesktopActivity(pid: process.processIdentifier)
        return poll(records, pid: process.processIdentifier, now: Date(), working: activity.working, viewed: activity.viewed)
    }
    private struct SavedReply {
        let messageID: UUID
        let ended: Date
    }

    func poll(_ records: [ClaudeDesktopLink.Metadata], pid: pid_t, now: Date,
              working: Set<String> = [], viewed: Set<String> = []) -> [AgentSession] {
        let rows = project(records, pid: pid, now: now, working: working, viewed: viewed)
        let byID = Dictionary(records.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        var folders: [URL]?
        var polledFiles = Set<URL>()
        defer { savedReplies = savedReplies.filter { polledFiles.contains($0.key) } }
        return rows.map { row in
            let recentlyViewed = row.lastViewedAt.map { now.timeIntervalSince($0) <= activeWindow } == true || row.sourceRead
            guard [.unknown, .completed].contains(row.state), !row.isChildSession,
                  (recentlyViewed || now.timeIntervalSince(row.lastActivityAt) <= activeWindow),
                  let id = row.claudeDesktopID, let record = byID[id],
                  let cli = row.claudeCanonicalID, let cliID = UUID(uuidString: cli),
                  record.lastAssistantCliSessionId.flatMap(UUID.init(uuidString:)) == cliID,
                  let messageID = record.lastAssistantUuid.flatMap(UUID.init(uuidString:)),
                  record.lastTurnCutShort != true, let userAt = record.latestUserFrameAt, userAt > 0,
                  let count = record.completedTurns, count > 0 else { return row }
            if folders == nil {
                folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            }
            let matches = (folders ?? []).map { projects.appendingPathComponent($0.lastPathComponent).appendingPathComponent(cli + ".jsonl") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard matches.count == 1, let file = matches.first else { return row }
            polledFiles.insert(file)
            guard let reply = savedReply(file, cli: cliID), reply.messageID == messageID,
                  reply.ended.timeIntervalSince1970 * 1000 >= userAt, reply.ended <= now,
                  (recentlyViewed || now.timeIntervalSince(reply.ended) <= activeWindow) else { return row }
            var result = row
            result.state = .completed
            result.completionRevision = "claude-desktop:\(id):\(count)"
            result.localCompletionRevision = "claude-end:\(reply.ended.timeIntervalSince1970)"
            if let seen = row.lastViewedAt, seen >= reply.ended { result.sourceRead = true }
            return result
        }
    }

    private func savedReply(_ file: URL, cli: UUID) -> SavedReply? {
        guard file.resolvingSymlinksInPath().path == file.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular, attrs[.ownerAccountID] as? UInt32 == getuid(),
              let modified = attrs[.modificationDate] as? Date, let inode = attrs[.systemFileNumber] as? UInt64,
              let size = attrs[.size] as? Int64, size > 0 else { return nil }
        if let cache = savedReplies[file], cache.0 == modified, cache.1 == inode, cache.2 == size { return cache.3 }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let offset = max(0, size - 262144)
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let bytes = try? handle.read(upToCount: Int(size - offset)), bytes.last == 10 else { return nil }
        let tail = offset == 0 ? bytes[...] : bytes.drop(while: { $0 != 10 }).dropFirst()
        let reply = Self.lastMainReply(tail, cli: cli)
        savedReplies[file] = (modified, inode, size, reply)
        return reply
    }

    private static func lastMainReply(_ tail: Data, cli: UUID) -> SavedReply? {
        for line in tail.split(separator: 10).reversed() {
            guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            guard frame["isSidechain"] as? Bool != true, let id = frame["sessionId"] as? String, UUID(uuidString: id) == cli,
                  let type = frame["type"] as? String, type == "assistant" || type == "user" else { continue }
            guard type == "assistant", frame["isApiErrorMessage"] as? Bool != true,
                  let message = frame["message"] as? [String: Any], message["stop_reason"] as? String == "end_turn",
                  let raw = frame["uuid"] as? String, let messageID = UUID(uuidString: raw),
                  let stamp = frame["timestamp"] as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { return nil }
            return SavedReply(messageID: messageID, ended: date)
        }
        return nil
    }

    /// All cached values contain only decoded metadata fields. File contents are not retained.
    func readRecords() -> [ClaudeDesktopLink.Metadata] {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil), accounts.count <= 32 else { return [] }
        var folders: [URL] = []
        for account in accounts where UUID(uuidString: account.lastPathComponent) != nil {
            guard let profiles = try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil), profiles.count <= 32 else { return [] }
            folders += profiles.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { root.appendingPathComponent(account.lastPathComponent).appendingPathComponent($0.lastPathComponent) }
        }
        // Do not guess the active account when more than one desktop profile is cached.
        guard folders.count == 1, let folder = folders.first,
              let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil), files.count <= 4096 else { return [] }
        var next: [URL: (Date, Int64, UInt64, ClaudeDesktopLink.Metadata)] = [:]
        var total: Int64 = 0
        for entry in files where entry.pathExtension == "json" && ClaudeDesktopLink.validDesktopID(entry.deletingPathExtension().lastPathComponent) {
            let file = folder.appendingPathComponent(entry.lastPathComponent)
            guard file.resolvingSymlinksInPath().path == file.path,
                  let attributes = try? fm.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType == .typeRegular,
                  attributes[.ownerAccountID] as? UInt32 == getuid(), let size = attributes[.size] as? Int64,
                  let modified = attributes[.modificationDate] as? Date, let inode = attributes[.systemFileNumber] as? UInt64,
                  size > 0, size <= 1_048_576 else { return [] }
            total += size; guard total <= 256 * 1024 * 1024 else { return [] }
            if let old = cache[file], old.0 == modified, old.1 == size, old.2 == inode { next[file] = old }
            else {
                guard let record = ClaudeDesktopLink.readFile(file, id: file.deletingPathExtension().lastPathComponent) else { return [] }
                next[file] = (modified, size, inode, record)
            }
        }
        cache = next
        return next.values.map { $0.3 }
    }
    func project(_ records: [ClaudeDesktopLink.Metadata], pid: pid_t, now: Date,
                 working: Set<String> = [], viewed: Set<String> = []) -> [AgentSession] {
        let ids = Set(records.map(\.sessionId)); counts = counts.filter { ids.contains($0.key) }; completions = completions.filter { ids.contains($0.key) }
        let cliCounts = Dictionary(grouping: records.compactMap { $0.cliSessionId.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() }, by: { $0 }).mapValues(\.count)
        return records.compactMap { record in
            guard record.isArchived != true, let ms = record.lastActivityAt, ms.isFinite, ms >= 0,
                  ms / 1000 <= now.timeIntervalSince1970 else { return nil }
            let at = Date(timeIntervalSince1970: ms / 1000)
            let id = record.sessionId
            if let count = record.completedTurns, count >= 0 {
                if let previous = counts[id], count > previous { completions[id] = ("claude-desktop:\(id):\(count)", at) }
                if let previous = counts[id], count < previous { completions[id] = nil }
                counts[id] = count
            }
            let canonical = record.cliSessionId.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
            let unique = canonical.flatMap { cliCounts[$0] == 1 ? $0 : nil }
            let completion = completions[id].flatMap { $0.at == at ? $0.revision : nil }
            let state: AgentState = record.interruptedAwaitingPerson == true ? .waitingForInput : working.contains(id) ? .working : completion != nil ? .completed : .unknown
            var session = AgentSession(id: unique.map { "claude:\($0)" } ?? "claude-desktop:\(id)", agentType: .claudeCode,
                state: state, hasUnreadCompletion: false, completionDetectedAt: nil, processId: Int(pid),
                projectPath: record.cwd, worktreePath: nil, sessionTitle: record.title, currentTask: nil,
                startedAt: at, lastActivityAt: at, isActive: working.contains(id) || record.interruptedAwaitingPerson == true,
                wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: nil, rateLimitResetAt: nil,
                tokens5h: 0, tokensWeek: 0, primaryLimit: nil, secondaryLimit: nil)
            session.claudeDesktopID = id; session.claudeCanonicalID = unique
            if let user = record.latestUserFrameAt, user.isFinite, user > 0 {
                let sent = Date(timeIntervalSince1970: user / 1000)
                session.claudeMessageAt = sent
                session.claudePromptPending = (0...120).contains(now.timeIntervalSince(sent))
            }
            session.statusSource = "desktop-metadata"; session.completionRevision = completion
            session.needsInput = record.interruptedAwaitingPerson == true
            session.isSubagent = record.spawnedFrom != nil && record.spawnedFrom?.userFork != true
            if let focused = record.lastFocusedAt, focused.isFinite, focused >= 0, focused / 1000 <= now.timeIntervalSince1970 {
                session.lastViewedAt = Date(timeIntervalSince1970: focused / 1000)
            }
            session.nativeSelected = viewed.contains(id)
            session.sourceRead = viewed.contains(id) // Only a live focused canonical window; historical focus is revision-specific.
            return session
        }
    }
}
