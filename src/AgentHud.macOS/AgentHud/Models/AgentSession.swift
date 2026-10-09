import Foundation

public struct LimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date

    public init(usedPercent: Double, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public func percentAt(_ now: Date) -> Double {
        now >= resetsAt ? 0 : usedPercent
    }
}

public struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let agentType: AgentType
    public var state: AgentState
    public var hasUnreadCompletion: Bool
    public var completionDetectedAt: Date?
    public var processId: Int?
    public var projectPath: String?
    public var worktreePath: String?
    public var sessionTitle: String?
    public var currentTask: String?
    public var startedAt: Date
    public var lastActivityAt: Date
    public var isActive: Bool
    public var wakeupAt: Date?
    public var hasBackgroundTasks: Bool
    public var parentSessionId: String?
    public var rateLimitResetAt: Date?
    public var tokens5h: Int64
    public var tokensWeek: Int64
    public var primaryLimit: LimitWindow?
    public var secondaryLimit: LimitWindow?

    public var displayState: AgentState {
        if hasUnreadCompletion { return .completed }
        if state == .completed { return .idle }
        return state
    }

    public var displayTitle: String {
        guard let title = sessionTitle, !title.isEmpty else { return "Untitled" }
        return title
    }

    public var projectName: String {
        guard let path = projectPath, !path.isEmpty else { return "Unknown" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Enum-style state name shown at the right of each row, matching the Windows app.
    public var displayStateName: String {
        switch displayState {
        case .unknown: return "Unknown"
        case .starting: return "Starting"
        case .working: return "Working"
        case .thinking: return "Thinking"
        case .waitingForInput: return "WaitingForInput"
        case .waitingForApproval: return "WaitingForApproval"
        case .completed: return "Completed"
        case .error: return "Error"
        case .stopped: return "Stopped"
        case .idle: return "Idle"
        case .rateLimited: return "RateLimited"
        }
    }

    public var statusTip: String {
        if let reset = rateLimitResetAt, displayState == .rateLimited {
            return HudTheme.formatPattern(
                Localiz.current.string("Session.RateLimitedReset"),
                [reset.formatted(date: .omitted, time: .shortened)]
            )
        }
        return displayStateName
    }
}
