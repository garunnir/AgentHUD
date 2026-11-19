import Foundation

/// Explicit source metadata only; names, cwd and fork IDs never establish ancestry.
enum CodexFamily {
    static func isChild(_ payload: [String: Any]) -> Bool {
        (payload["parent_thread_id"] != nil && !(payload["parent_thread_id"] is NSNull)) || ((payload["source"] as? [String: Any])?["subagent"].map { !($0 is NSNull) } ?? false)
    }
    static func parentID(_ payload: [String: Any], ownID: String) -> String? {
        let sub = (payload["source"] as? [String: Any])?["subagent"] as? [String: Any]
        let nested = (sub?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String
        let top = payload["parent_thread_id"] as? String
        if let top, let nested, top.lowercased() != nested.lowercased() { return nil }
        guard let raw = top ?? nested, let uuid = UUID(uuidString: raw),
              uuid.uuidString.lowercased() != ownID.lowercased() else { return nil }
        return "codex:\(uuid.uuidString.lowercased())"
    }
}

struct SessionListRow: Identifiable {
    let session: AgentSession
    let hasRunningDescendants: Bool
    var id: String { session.id }
    var statusName: String {
        hasRunningDescendants && [.idle, .unknown, .completed].contains(session.displayState) ? "Working" : session.displayStateName
    }
    var statusTip: String { hasRunningDescendants ? "Working · " + session.statusTip : session.statusTip }
}

/// Discovery keeps children for execution evidence; presentation only exposes root threads.
enum SessionListPolicy {
    static func isRunning(_ s: AgentSession) -> Bool {
        [.working, .thinking, .starting].contains(s.displayState)
    }
    static func needsAttention(_ s: AgentSession) -> Bool {
        s.hasUnreadCompletion || s.sourceUnread == true || s.needsInput ||
            [.working, .thinking, .starting, .waitingForInput, .waitingForApproval].contains(s.displayState)
    }
    static func rows(_ sessions: [AgentSession], hidden: Set<String> = [],
                     now: Date = Date(), activeWindow: TimeInterval = 3600) -> [SessionListRow] {
        let available = sessions.filter { !$0.isAppActivity }
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func rootID(_ s: AgentSession) -> String? {
            var depth = 0; var seen: Set<String> = [s.id]; var current = s
            while current.isChildSession {
                guard depth < 64, let parent = current.parentSessionId, let next = byID[parent],
                      next.agentType == s.agentType, seen.insert(parent).inserted else { return nil }
                depth += 1; current = next
            }
            return current.id
        }
        func recent(_ date: Date?) -> Bool {
            guard let date else { return false }; let age = now.timeIntervalSince(date)
            return age >= 0 && age <= activeWindow
        }
        // An unread completion is kept on disk until acknowledged, but only keeps its row
        // listed while the conversation itself is within the activity window.
        func attention(_ s: AgentSession) -> Bool {
            if s.sourceUnread == true || s.needsInput
                || [.working, .thinking, .starting, .waitingForInput, .waitingForApproval].contains(s.displayState) { return true }
            return s.hasUnreadCompletion && recent(s.hasStableLocalIdentity ? s.lastActivityAt : s.nativeActivityAt ?? s.completionDetectedAt)
        }
        let runningRoots = Set(available.filter { $0.isChildSession && isRunning($0) }.compactMap(rootID))
        let roots = available.filter { s in
            guard !s.isChildSession, !hidden.contains(s.id) else { return false }
            let isRecent = !s.hasStableLocalIdentity
                ? recent(s.nativeActivityAt) || (s.agentType == .amp && recent(s.lastViewedAt))
                : recent(s.lastActivityAt) || (s.claudeDesktopID != nil && recent(s.lastViewedAt))
            return runningRoots.contains(s.id) || attention(s) || isRecent || (s.rateLimitResetAt.map { $0 > now } ?? false)
        }
        return roots.enumerated().sorted {
            let l = attention($0.element) || runningRoots.contains($0.element.id)
            let r = attention($1.element) || runningRoots.contains($1.element.id)
            return l == r ? $0.offset < $1.offset : l
        }.map { SessionListRow(session: $0.element, hasRunningDescendants: runningRoots.contains($0.element.id)) }
    }
}
