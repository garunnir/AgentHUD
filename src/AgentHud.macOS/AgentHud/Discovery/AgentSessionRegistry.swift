import Foundation

public final class AgentSessionRegistry {
    private let timeProvider: () -> Date
    private var sessions: [String: AgentSession] = [:]
    private let lock = NSLock()
    public var onChanged: (() -> Void)?

    public init(timeProvider: @escaping () -> Date = { Date() }) {
        self.timeProvider = timeProvider
    }

    public func getAllAgents() -> [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.sorted {
            $0.lastActivityAt > $1.lastActivityAt || ($0.lastActivityAt == $1.lastActivityAt && $0.startedAt > $1.startedAt)
        }
    }

    public func getActiveAgents() -> [AgentSession] {
        getAllAgents().filter { $0.isActive }
    }

    public func getByProject(_ path: String) -> [AgentSession] {
        getAllAgents().filter { $0.projectPath == path }
    }

    public func getByAgentType(_ type: AgentType) -> [AgentSession] {
        getAllAgents().filter { $0.agentType == type }
    }

    public func findSession(_ id: String) -> AgentSession? {
        getAllAgents().first { $0.id == id }
    }

    public func acknowledgeCompletion(_ id: String) {
        lock.lock()
        if var session = sessions[id], session.hasUnreadCompletion {
            session.hasUnreadCompletion = false
            session.completionDetectedAt = nil
            sessions[id] = session
            lock.unlock()
            onChanged?()
        } else {
            lock.unlock()
        }
    }

    public func replace(_ newSessions: [AgentSession]) {
        let latest = Dictionary(grouping: newSessions, by: { $0.id })
            .compactMapValues { $0.max(by: { $0.lastActivityAt < $1.lastActivityAt }) }

        lock.lock()
        var tracked: [String: AgentSession] = [:]
        for (id, session) in latest {
            tracked[id] = trackCompletion(session)
        }
        for (id, previous) in sessions where previous.hasUnreadCompletion && tracked[id] == nil {
            var retained = previous
            retained.isActive = false
            retained = trackCompletion(retained)
            if retained.hasUnreadCompletion {
                tracked[id] = retained
            }
        }
        sessions = tracked
        lock.unlock()
        onChanged?()
    }

    private func trackCompletion(_ session: AgentSession) -> AgentSession {
        var session = session
        let now = timeProvider()
        if session.state == .starting || session.state == .working || session.state == .thinking
            || session.state == .waitingForInput || session.state == .waitingForApproval {
            session.hasUnreadCompletion = false
            session.completionDetectedAt = nil
            return session
        }
        if session.state == .idle && (session.hasBackgroundTasks || (session.wakeupAt ?? .distantPast) > now) {
            session.hasUnreadCompletion = false
            session.completionDetectedAt = nil
            return session
        }

        let previous = sessions[session.id]
        let completed = (session.state == .idle || session.state == .completed)
            && (previous?.state == .working || previous?.state == .thinking || previous?.state == .waitingForApproval)
        var detectedAt: Date?
        if completed || (session.state == .completed && previous?.state != .completed) {
            detectedAt = now
        } else {
            detectedAt = previous?.completionDetectedAt
        }

        var unread = (previous?.hasUnreadCompletion == true || completed
            || (session.state == .completed && previous?.state != .completed))
            && detectedAt != nil && now.timeIntervalSince(detectedAt!) < 300

        session.hasUnreadCompletion = unread
        session.completionDetectedAt = unread ? detectedAt : nil
        return session
    }
}
