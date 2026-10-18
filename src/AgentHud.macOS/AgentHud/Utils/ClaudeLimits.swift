import Foundation

/// Swift port of `src/AgentHud.Core/ClaudeLimits.cs` (the reference implementation —
/// keep both in sync). There is no sessionKey API port on macOS, so `api` is always
/// `.none` here; the parameter stays so both ports share the same `pick` signature.
public enum ClaudeLimitSource: Sendable {
    case none, statusLine, usageApi
}

public struct ClaudeLimitSnapshot: Sendable {
    public let source: ClaudeLimitSource
    public let fiveHour: LimitWindow?
    public let sevenDay: LimitWindow?
    public let updatedAt: Date

    public static let none = ClaudeLimitSnapshot(source: .none, fiveHour: nil, sevenDay: nil, updatedAt: .distantPast)

    public var hasData: Bool { fiveHour != nil || sevenDay != nil }

    /// Claude Code statusLine script's stdin JSON:
    /// {"rate_limits":{"five_hour":{"used_percentage":..,"resets_at":<epoch s>},"seven_day":{..}}}
    public static func parseStatusLine(_ json: String, updatedAt: Date) -> ClaudeLimitSnapshot {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return .none }
        let five = window(limits["five_hour"] as? [String: Any])
        let seven = window(limits["seven_day"] as? [String: Any])
        if five == nil && seven == nil { return .none }
        return ClaudeLimitSnapshot(source: .statusLine, fiveHour: five, sevenDay: seven, updatedAt: updatedAt)
    }

    private static func window(_ w: [String: Any]?) -> LimitWindow? {
        guard let w,
              let used = w["used_percentage"] as? Double,
              let seconds = w["resets_at"] as? Double else { return nil }
        return LimitWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: seconds))
    }
}

/// Chosen value and per-window staleness. The HUD marks the last known value as stale when
/// the matching `*Stale` flag is true (or, if that window's `resetsAt` has already passed,
/// shows no number at all since it would be meaningless). `updatedAt` is the chosen
/// snapshot's timestamp, used to explain staleness in the tooltip.
public struct ClaudeLimitPick: Sendable {
    public let source: ClaudeLimitSource
    public let fiveHour: LimitWindow?
    public let sevenDay: LimitWindow?
    public let fiveHourStale: Bool
    public let sevenDayStale: Bool
    public let updatedAt: Date
}

/// Picks the fresher, valid value between the statusLine (default, official CLI value)
/// and the sessionKey API (optional, unofficial). See `ClaudeLimitPolicy` in
/// `src/AgentHud.Core/ClaudeLimits.cs` for the full rationale; the thresholds below must
/// match it exactly.
public enum ClaudeLimitPolicy {
    public static let statusLineMaxAge: TimeInterval = 12 * 3600
    public static let apiMaxAge: TimeInterval = 30 * 60
    public static let activityGrace: TimeInterval = 15 * 60

    public static func isStale(_ snapshot: ClaudeLimitSnapshot, now: Date, lastClaudeActivity: Date?) -> Bool {
        if !snapshot.hasData { return true }
        let maxAge = snapshot.source == .statusLine ? statusLineMaxAge : apiMaxAge
        if now.timeIntervalSince(snapshot.updatedAt) > maxAge { return true }
        if snapshot.source == .statusLine, let activity = lastClaudeActivity,
           activity > snapshot.updatedAt.addingTimeInterval(activityGrace) { return true }
        return false
    }

    public static func pick(statusLine: ClaudeLimitSnapshot, api: ClaudeLimitSnapshot, now: Date, lastClaudeActivity: Date?) -> ClaudeLimitPick {
        let slCandidate = statusLine.hasData
        let apiCandidate = api.hasData
        if !slCandidate && !apiCandidate {
            return ClaudeLimitPick(source: .none, fiveHour: nil, sevenDay: nil, fiveHourStale: false, sevenDayStale: false, updatedAt: .distantPast)
        }

        let slStale = slCandidate && isStale(statusLine, now: now, lastClaudeActivity: lastClaudeActivity)
        let apiStale = apiCandidate && isStale(api, now: now, lastClaudeActivity: lastClaudeActivity)

        let chosen: ClaudeLimitSnapshot
        let stale: Bool
        if slCandidate && apiCandidate {
            if !slStale && !apiStale {
                chosen = statusLine.updatedAt >= api.updatedAt ? statusLine : api
                stale = false
            } else if !slStale {
                chosen = statusLine
                stale = false
            } else if !apiStale {
                chosen = api
                stale = false
            } else {
                chosen = statusLine.updatedAt >= api.updatedAt ? statusLine : api
                stale = true
            }
        } else if slCandidate {
            chosen = statusLine
            stale = slStale
        } else {
            chosen = api
            stale = apiStale
        }

        let fiveStale = stale || (chosen.fiveHour?.resetsAt.map { $0 <= now } ?? false)
        let sevenStale = stale || (chosen.sevenDay?.resetsAt.map { $0 <= now } ?? false)
        return ClaudeLimitPick(source: chosen.source, fiveHour: chosen.fiveHour, sevenDay: chosen.sevenDay,
                               fiveHourStale: fiveStale, sevenDayStale: sevenStale, updatedAt: chosen.updatedAt)
    }
}
