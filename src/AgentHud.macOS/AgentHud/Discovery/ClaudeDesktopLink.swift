import Foundation
import Darwin

/// Claude's own local desktop-ID -> transcript-ID relationship; no title-only identity join.
struct ClaudeDesktopLink: Decodable, Equatable, Sendable {
    let sessionId: String
    let cliSessionId: String
    let title: String?
    var url: URL? { Self.validDesktopID(sessionId) ? URL(string: "claude://claude.ai/epitaxy/" + sessionId) : nil }
    struct Metadata: Decodable, Sendable {
        let sessionId: String
        let cliSessionId: String?
        let title: String?
        let cwd: String?
        let createdAt: Double?
        let lastActivityAt: Double?
        let lastFocusedAt: Double?
        let completedTurns: Int?
        let lastAssistantUuid: String?
        let lastAssistantCliSessionId: String?
        let latestUserFrameAt: Double?
        let lastTurnCutShort: Bool?
        let isArchived: Bool?
        let interruptedAwaitingPerson: Bool?
        let spawnedFrom: Spawn?
        struct Spawn: Decodable, Sendable { let userFork: Bool? }
        var url: URL? { ClaudeDesktopLink.validDesktopID(sessionId) ? URL(string: "claude://claude.ai/epitaxy/" + sessionId) : nil }
        var link: ClaudeDesktopLink? {
            guard let cliSessionId, UUID(uuidString: cliSessionId) != nil else { return nil }
            return ClaudeDesktopLink(sessionId: sessionId, cliSessionId: cliSessionId, title: title)
        }
    }
    static func validDesktopID(_ id: String) -> Bool {
        id.hasPrefix("local_") && UUID(uuidString: String(id.dropFirst(6))) != nil
    }
    static func desktopID(from url: String?) -> String? {
        guard let url, let value = URL(string: url), value.scheme == "https", value.host == "claude.ai",
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.pathComponents.count == 3, value.pathComponents[1] == "epitaxy",
              validDesktopID(value.pathComponents[2]) else { return nil }
        return value.pathComponents[2]
    }
    static func find(cliID: String, home: String = NSHomeDirectory()) -> Self? {
        guard let uuid = UUID(uuidString: cliID) else { return nil }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Claude/claude-code-sessions").resolvingSymlinksInPath()
        var matches: [Self] = []; var count = 0; var bytes: Int64 = 0
        guard let accounts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil), accounts.count <= 32 else { return nil }
        for account in accounts where UUID(uuidString: account.lastPathComponent) != nil {
            guard let profiles = try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil), profiles.count <= 32 else { return nil }
            for profile in profiles where UUID(uuidString: profile.lastPathComponent) != nil {
                guard let files = try? fm.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil), files.count <= 4096 else { return nil }
                for file in files where file.pathExtension == "json" && validDesktopID(file.deletingPathExtension().lastPathComponent) {
                    count += 1
                    let path = root.appendingPathComponent(account.lastPathComponent).appendingPathComponent(profile.lastPathComponent).appendingPathComponent(file.lastPathComponent)
                    guard count <= 4096, path.resolvingSymlinksInPath().path == path.path,
                          let attributes = try? fm.attributesOfItem(atPath: path.path), let size = attributes[.size] as? Int64 else { return nil }
                    bytes += size; guard bytes <= 256 * 1024 * 1024 else { return nil }
                    guard let metadata = readFile(path, id: file.deletingPathExtension().lastPathComponent) else { return nil }
                    guard let cli = metadata.cliSessionId, !cli.isEmpty else { continue }
                    guard let link = metadata.link else { return nil }
                    if UUID(uuidString: link.cliSessionId) == uuid { matches.append(link) }
                }
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
    static func read(_ id: String, home: String = NSHomeDirectory()) -> Self? { readMetadata(id, home: home)?.link }
    static func readMetadata(_ id: String, home: String = NSHomeDirectory()) -> Metadata? {
        guard validDesktopID(id) else { return nil }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Claude/claude-code-sessions").resolvingSymlinksInPath()
        var matches: [URL] = []
        for account in ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).prefix(32) where UUID(uuidString: account.lastPathComponent) != nil {
            for profile in ((try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? []).prefix(32) where UUID(uuidString: profile.lastPathComponent) != nil {
                let file = root.appendingPathComponent(account.lastPathComponent).appendingPathComponent(profile.lastPathComponent).appendingPathComponent(id + ".json")
                if fm.fileExists(atPath: file.path) { matches.append(file) }
            }
        }
        guard matches.count == 1, let file = matches.first,
              file.resolvingSymlinksInPath().path == file.path else { return nil }
        return readFile(file, id: id)
    }
    static func readFile(_ file: URL, id: String) -> Metadata? {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= 1_048_576,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 1_048_577),
              let link = try? JSONDecoder().decode(Metadata.self, from: data), link.sessionId == id else { return nil }
        return link
    }
}

/// Canonical desktop metadata and local logs are joined by explicit CLI UUID, never by UI labels.
enum ClaudeSessionCoalescer {
    static func merge(_ sessions: [AgentSession]) -> [AgentSession] {
        let desktop = sessions.filter { $0.agentType == .claudeCode && $0.claudeDesktopID != nil }
        let locals = sessions.filter { $0.claudeDesktopID == nil }
        let groups = Dictionary(grouping: desktop, by: \.id)
        let localCounts = Dictionary(grouping: locals, by: \.id).mapValues(\.count)
        var consumed = Set<String>()
        let result = locals.map { local -> AgentSession in
            guard local.agentType == .claudeCode, local.id.hasPrefix("claude:"),
                  let matches = groups[local.id], matches.count == 1, let source = matches.first,
                  localCounts[local.id] == 1 else { return local }
            consumed.insert(source.id)
            var merged = local
            merged.claudeDesktopID = source.claudeDesktopID; merged.claudeCanonicalID = source.claudeCanonicalID
            merged.nativeProcessId = source.processId; merged.localCompletionRevision = local.localCompletionRevision ?? local.completionRevision
            merged.lastViewedAt = source.lastViewedAt
            merged.lastActivityAt = max(local.lastActivityAt, source.lastActivityAt)
            merged.isSubagent = source.isSubagent == true || local.isChildSession
            merged.sourceRead = source.sourceRead
            func endDate(_ revision: String?) -> Date? {
                guard let revision, revision.hasPrefix("claude-end:"),
                      let seconds = Double(revision.dropFirst("claude-end:".count)), seconds.isFinite else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
            let localEnd = endDate(merged.localCompletionRevision)
            let localMessage = [localEnd, local.claudeMessageAt].compactMap { $0 }.max()
            let sourceEnd = endDate(source.localCompletionRevision) ?? source.lastActivityAt
            let strong: [AgentState] = [.waitingForInput, .waitingForApproval, .error, .rateLimited]
            if !strong.contains(local.state) {
                if source.state == .completed && (localMessage ?? .distantPast) > sourceEnd {
                    // A newer user/assistant frame supersedes this specific desktop completion.
                    if source.localCompletionRevision != nil, source.nativeSelected == false {
                        merged.sourceRead = source.lastViewedAt.map { $0 >= (localMessage ?? .distantFuture) } ?? false
                    }
                } else if source.state != .unknown {
                    merged.state = source.state; merged.completionRevision = source.completionRevision
                    if source.state == .completed { merged.localCompletionRevision = source.localCompletionRevision }
                } else if let end = localEnd {
                    if let user = source.claudeMessageAt, user > end {
                        merged.state = source.claudePromptPending == true && local.state != .stopped ? .working : .unknown
                        merged.completionRevision = nil
                        merged.localCompletionRevision = nil
                    } else {
                        merged.state = .completed
                        merged.completionRevision = merged.localCompletionRevision
                    }
                }
            }
            if local.claudePromptPending == true, [.idle, .unknown].contains(merged.state) {
                merged.state = .working
            }
            if let revision = merged.completionRevision, revision.hasPrefix("claude-end:"),
               let seconds = Double(revision.dropFirst("claude-end:".count)), seconds.isFinite,
               let viewed = source.lastViewedAt, viewed.timeIntervalSince1970 >= seconds { merged.sourceRead = true }
            merged.needsInput = local.needsInput || source.needsInput
            merged.isActive = local.isActive || source.isActive
            merged.statusSource = "desktop+local"
            return merged
        }
        return result + desktop.filter { !consumed.contains($0.id) }
    }
}
