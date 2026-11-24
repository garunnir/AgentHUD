import Foundation

/// Consumes metadata-only collectors; compatible with the already trusted Threaddeck hooks/plugin.
/// No source transcripts, credentials, or tool inputs are read by this bridge.
public final class LiveActivityOverlay {
    private let roots: [URL]
    private let now: () -> Date
    private var observed: [String: ActivityRecord] = [:]
    public init(roots: [URL], now: @escaping () -> Date = Date.init) { self.roots = roots; self.now = now }
    public static func defaultRoots(home: URL) -> [URL] {
        ["AgentHud", "Threaddeck"].map { home.appendingPathComponent("Library/Application Support/\($0)/activity") }
    }
    public func apply(_ sessions: [AgentSession]) -> [AgentSession] {
        let identities = sessions.filter { $0.isAncestorContext != true }.compactMap(Self.identity)
        var records: [String: ActivityRecord] = [:]
        var liveKeys = Set<String>()
        for root in roots {
            let result = ActivityFileStore.read(identities: identities, root: root, now: now())
            for record in result.records {
                if let chosen = records[record.key], chosen.timestamp > record.timestamp
                    || (chosen.timestamp == record.timestamp && chosen.sequence >= record.sequence) { continue }
                liveKeys.remove(record.key)
                records[record.key] = record
                if result.liveProducers.contains(record.producer) { liveKeys.insert(record.key) }
            }
        }
        return sessions.map { original in
            guard original.isAncestorContext != true, let identity = Self.identity(original) else { return original }
            let key = "\(identity.app.rawValue):\(identity.sessionID)"
            if let record = records[key] {
                let previous = observed[key]
                if previous == nil || record.timestamp > previous!.timestamp
                    || (record.timestamp == previous!.timestamp && record.sequence > previous!.sequence) {
                    observed[key] = record
                }
            }
            guard let record = observed[key] else { return original }
            var session = original
            // A missing/expired source does not resurrect an old log's Working state.
            let current = records[key]?.eventID == record.eventID
            let fresh = current && liveKeys.contains(key)
            // Later transcript events (e.g. a new turn or answered question) remain authoritative.
            let eventAt = Date(timeIntervalSince1970: record.timestamp / 1000)
            if let turn = original.currentTurnID, let sourceTurn = record.turnID, turn != sourceTurn,
               original.lastActivityAt >= eventAt { return original }
            let sameTurn = record.turnID != nil && record.turnID == original.currentTurnID
            if record.state == "running", (sameTurn || original.lastActivityAt >= eventAt),
               [.completed, .stopped, .error, .rateLimited].contains(original.state) { return original }
            if record.state != "running", original.state != .unknown,
               original.lastActivityAt > eventAt.addingTimeInterval(1) { return original }
            if !sameTurn, record.turnID != nil, original.currentTurnID != nil { session.localCompletionRevision = nil }
            session.statusSource = "lifecycle"
            switch record.state {
            case "running": session.state = fresh ? .working : .unknown; session.completionRevision = nil
            case "completed": session.state = .completed; session.completionRevision = record.turnID.map { "turn:\($0)" } ?? record.eventID
            case "failed": session.state = .error; session.completionRevision = nil
            case "interrupted": session.state = .stopped; session.completionRevision = nil
            default: session.state = .unknown
            }
            if record.state == "running", original.state == .waitingForInput || original.state == .waitingForApproval {
                session.state = original.state
            }
            session.lastActivityAt = max(original.lastActivityAt, eventAt)
            return session
        }
    }
    private static func identity(_ session: AgentSession) -> ActivityIdentity? {
        let app: AgentApp
        let prefix: String
        switch session.agentType {
        case .codex: app = .chatGPT; prefix = "codex:"
        case .openCode, .openCodeGo: app = .openCode; prefix = "opencode:"
        default: return nil
        }
        guard session.id.hasPrefix(prefix) else { return nil }
        let id = String(session.id.dropFirst(prefix.count))
        guard ActivityFileStore.validSessionID(id, app: app) else { return nil }
        return ActivityIdentity(app: app, sessionID: id)
    }
}
