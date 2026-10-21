import Foundation

/// Picks sessions whose usage-limit reset time has passed, once per (session, reset time)
/// (port of the Windows RateLimitNotifier).
public final class RateLimitNotifier {
    private let now: () -> Date
    private var notified: Set<String> = []

    public init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    public func takeDue(_ sessions: [AgentSession]) -> [AgentSession] {
        let now = self.now()
        return sessions.filter { session in
            // A limit that reset long ago (HUD was closed) is not announced.
            guard let reset = session.rateLimitResetAt, session.parentSessionId == nil,
                  now >= reset, now < reset.addingTimeInterval(CodexProvider.limitGrace) else { return false }
            return notified.insert("\(session.id)|\(reset.timeIntervalSince1970)").inserted
        }
    }
}
