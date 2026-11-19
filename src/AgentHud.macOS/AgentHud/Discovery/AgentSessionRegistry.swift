import Foundation
import Darwin

/// Completion is keyed by an explicit revision. A failed navigation or an old click cannot consume a newer result.
public final class AgentSessionRegistry {
    private struct Saved: Codable {
        var acknowledged: [String: String] = [:]
        var pending: [String: AgentSession] = [:]
        var viewed: [String: Date]? = nil
        var acknowledgedLocal: [String: String]? = nil
    }
    private let timeProvider: () -> Date
    private let storageURL: URL?
    private var saved = Saved()
    private var lastPersisted: Data?
    private var sessions: [String: AgentSession] = [:]
    private let lock = NSLock()
    public var onChanged: (() -> Void)?

    public init(timeProvider: @escaping () -> Date = { Date() }, storageURL: URL? = nil) {
        self.timeProvider = timeProvider
        self.storageURL = storageURL
        if let url = storageURL, let data = Self.readPrivateFile(url),
           let value = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = value
            func canonical(_ key: String) -> String {
                if key.hasPrefix("codex:"), let uuid = UUID(uuidString: String(key.dropFirst(6))) {
                    return "codex:" + uuid.uuidString.lowercased()
                }
                let prefix = "desktop:amp:"
                if key.hasPrefix(prefix), let id = ThreadExtractor.ampSessionID(String(key.dropFirst(prefix.count))) {
                    return prefix + "https://ampcode.com/threads/" + id
                }
                return key
            }
            for (old, revision) in value.acknowledged where canonical(old) != old {
                saved.acknowledged[canonical(old)] = saved.acknowledged[canonical(old)] ?? revision
                saved.acknowledged[old] = nil
            }
            for (old, date) in value.viewed ?? [:] where canonical(old) != old {
                let latest = max(date, saved.viewed?[canonical(old)] ?? .distantPast)
                saved.viewed?[canonical(old)] = latest
                saved.viewed?[old] = nil
            }
            for (old, var pending) in value.pending where canonical(old) != old {
                pending.id = canonical(old)
                if let parent = pending.parentSessionId { pending.parentSessionId = canonical(parent) }
                if pending.lastActivityAt >= (saved.pending[pending.id]?.lastActivityAt ?? .distantPast) {
                    saved.pending[pending.id] = pending
                }
                saved.pending[old] = nil
            }
            saved.pending = saved.pending.filter { $0.value.hasStableLocalIdentity && !$0.value.isChildSession }.mapValues(Self.withoutNativeRoute)
            saved.acknowledged = saved.acknowledged.filter { Self.keepsAcknowledgement($0.key) }
            sessions = saved.pending.mapValues { session in
                var restored = session; restored.isActive = false
                restored.nativeThreadID = nil; restored.nativeProcessId = nil; restored.claudeCanonicalID = nil
                return restored
            }
        }
    }
    public func getAllAgents() -> [AgentSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.sorted {
            let left = Self.priority($0), right = Self.priority($1)
            if left != right { return left < right }
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id < $1.id
        }
    }
    private static func priority(_ session: AgentSession) -> Int {
        if session.needsInput || [.working, .thinking, .starting, .waitingForInput, .waitingForApproval, .error, .rateLimited].contains(session.displayState) { return 0 }
        return session.hasUnreadCompletion || session.sourceUnread == true ? 1 : 2
    }
    public func getActiveAgents() -> [AgentSession] { getAllAgents().filter(\.isActive) }
    public func getByProject(_ path: String) -> [AgentSession] { getAllAgents().filter { $0.projectPath == path } }
    public func getByAgentType(_ type: AgentType) -> [AgentSession] { getAllAgents().filter { $0.agentType == type } }
    public func findSession(_ id: String) -> AgentSession? { getAllAgents().first { $0.id == id } }

    public func acknowledgeCompletion(_ id: String, revision: String?) {
        lock.lock()
        guard let revision, var session = sessions[id], session.completionRevision == revision,
              session.hasUnreadCompletion else { lock.unlock(); return }
        saved.acknowledged[id] = revision
        if let local = session.localCompletionRevision { saved.acknowledgedLocal = saved.acknowledgedLocal ?? [:]; saved.acknowledgedLocal?[id] = local }
        saved.pending[id] = nil
        session.hasUnreadCompletion = false; session.completionDetectedAt = nil
        sessions[id] = session
        persist()
        lock.unlock(); onChanged?()
    }
    /// Successful Amp navigation retains the row without clearing source unread or inventing work.
    public func recordNavigation(_ id: String, result: ConversationOpenResult) {
        guard result == .nativeSelectionAccepted else { return }
        lock.lock()
        guard var session = sessions[id], session.agentType == .amp, session.nativeThreadID != nil else { lock.unlock(); return }
        let now = timeProvider()
        session.lastViewedAt = now
        saved.viewed = saved.viewed ?? [:]; saved.viewed?[id] = now
        sessions[id] = session
        pruneViews(now: now); persist()
        lock.unlock(); onChanged?()
    }
    private func pruneViews(now: Date) {
        // Persist only a bounded recent timestamp index, never cached native rows or AX identities.
        let recent = (saved.viewed ?? [:]).filter { now.timeIntervalSince($0.value) >= 0 && now.timeIntervalSince($0.value) <= 7 * 86400 }
        saved.viewed = Dictionary(uniqueKeysWithValues: recent.sorted { $0.value > $1.value }.prefix(1024).map { ($0.key, $0.value) })
    }
    public func replace(_ newSessions: [AgentSession]) {
        let latest = Dictionary(grouping: newSessions, by: \.id)
            .compactMapValues { $0.max { $0.lastActivityAt < $1.lastActivityAt } }
        lock.lock()
        let now = timeProvider(); pruneViews(now: now)
        var tracked: [String: AgentSession] = [:]
        for (id, original) in latest {
            var session = original
            let previous = sessions[id]
            // Child rows have no review UI. Keep live source execution but never retain
            // an unacknowledgeable child completion after discovery drops the child.
            if session.isChildSession {
                session.hasUnreadCompletion = false; session.completionDetectedAt = nil
                saved.pending[id] = nil; saved.acknowledged[id] = nil
                tracked[id] = session
                continue
            }
            if session.agentType == .amp, session.nativeThreadID != nil {
                // A validated unread -> read transition also covers checking the thread in Amp itself.
                // Initial plain/selected rows and repeated read polls do not renew the timestamp.
                if previous?.sourceUnread == true, session.sourceUnread == false { saved.viewed?[id] = now }
                session.lastViewedAt = saved.viewed?[id]
            }
            if session.sourceRead, let local = session.localCompletionRevision ?? previous?.localCompletionRevision {
                saved.acknowledgedLocal = saved.acknowledgedLocal ?? [:]; saved.acknowledgedLocal?[id] = local
            }
            if session.sourceRead, let revision = session.completionRevision ?? previous?.completionRevision {
                saved.acknowledged[id] = revision
                saved.pending[id] = nil
            }
            // Only an explicit terminal observation creates a completion.
            if session.state == .completed, let revision = session.completionRevision {
                let acknowledged = [saved.acknowledged[id], saved.acknowledgedLocal?[id]].compactMap { $0 }
                let aliases = [revision, session.localCompletionRevision].compactMap { $0 }
                let canNotify = session.completionIsBaseline != true || saved.pending[id]?.completionRevision == revision
                session.hasUnreadCompletion = canNotify && !session.sourceRead && Set(acknowledged).isDisjoint(with: aliases)
                if !session.hasUnreadCompletion, let local = session.localCompletionRevision {
                    saved.acknowledged[id] = revision
                    saved.acknowledgedLocal = saved.acknowledgedLocal ?? [:]
                    saved.acknowledgedLocal?[id] = local
                }
                session.completionDetectedAt = session.hasUnreadCompletion
                    ? (previous?.completionRevision == revision ? previous?.completionDetectedAt ?? timeProvider() : timeProvider()) : nil
            } else if session.state == .unknown, let pending = saved.pending[id], !session.sourceRead,
                      session.agentType != .gemini || pending.currentTurnID == session.currentTurnID {
                session.hasUnreadCompletion = true
                session.completionRevision = pending.completionRevision
                session.completionDetectedAt = pending.completionDetectedAt
            } else {
                session.hasUnreadCompletion = false; session.completionDetectedAt = nil
            }
            if session.hasUnreadCompletion { saved.pending[id] = session }
            else { saved.pending[id] = nil }
            tracked[id] = session
        }
        for (id, pending) in saved.pending where tracked[id] == nil {
            guard pending.hasStableLocalIdentity, !pending.isChildSession else { saved.pending[id] = nil; saved.acknowledged[id] = nil; continue }
            var retained = pending; retained.isActive = false
            tracked[id] = retained
        }
        pruneViews(now: now)
        sessions = tracked
        persist()
        lock.unlock(); onChanged?()
    }
    private static func keepsAcknowledgement(_ id: String) -> Bool {
        if !id.hasPrefix("desktop:") { return true }
        let prefix = "desktop:amp:"
        guard id.hasPrefix(prefix) else { return false }
        return ThreadExtractor.ampSessionID(String(id.dropFirst(prefix.count))) != nil
    }

    private static func withoutNativeRoute(_ original: AgentSession) -> AgentSession {
        var session = original
        session.nativeThreadID = nil; session.nativeProcessId = nil; session.claudeCanonicalID = nil
        return session
    }
    private func persist() {
        guard let url = storageURL else { return }
        // AX row identities last only as long as the source element. The source unread marker restores them.
        let disk = Saved(acknowledged: saved.acknowledged.filter { Self.keepsAcknowledgement($0.key) },
                         pending: saved.pending.filter { $0.value.hasStableLocalIdentity && !$0.value.isChildSession }.mapValues(Self.withoutNativeRoute), viewed: saved.viewed, acknowledgedLocal: saved.acknowledgedLocal)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(disk), data.count <= 4_194_304, data != lastPersisted else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  attributes[.ownerAccountID] as? UInt32 == getuid() else { return }
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastPersisted = data
        } catch { NSLog("Completion state could not be saved") }
    }
    private static func readPrivateFile(_ url: URL) -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0,
              attributes.st_size > 0, attributes.st_size <= 4_194_304 else { return nil }
        return try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 4_194_305)
    }

}
