import Foundation

public struct LimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date?
    /// Window length reported by the server (minutes). Used for the even-pace marker,
    /// since plans do not always use a 5 h / 7 day window.
    public let windowMinutes: Int?

    public init(usedPercent: Double, resetsAt: Date?, windowMinutes: Int? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }

    public func percentAt(_ now: Date) -> Double {
        guard let resetsAt else { return usedPercent }
        return now >= resetsAt ? 0 : usedPercent
    }
}

public struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    public internal(set) var id: String
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
    /// When the rate-limit snapshot above was recorded. Limits are account-wide, so the
    /// freshest snapshot wins rather than the most recently active session.
    public var limitsUpdatedAt: Date?

    /// Evidence is independent of presentation and never inferred from a missing heartbeat.
    public var completionRevision: String? = nil
    public var needsInput: Bool = false
    public var sourceRead: Bool = false
    public var statusSource: String? = nil
    public var nativeThreadID: String? = nil
    public var nativeProcessId: Int? = nil
    // Message evidence is independent of process heartbeats and opening a desktop window.
    var claudePromptPending: Bool? = nil
    var claudeMessageAt: Date? = nil
    public var claudeCanonicalID: String? = nil
    public var claudeDesktopID: String? = nil
    public var localCompletionRevision: String? = nil
    public var hasStableLocalIdentity: Bool {
        nativeThreadID == nil || (agentType == .claudeCode && id.hasPrefix("claude:") && UUID(uuidString: String(id.dropFirst(7))) != nil)
    }
    public var currentTurnID: String? = nil
    /// Optional for old completion-state files; nil means the source did not expose unread status.
    public var sourceUnread: Bool? = nil
    /// The source confirms an existing result but did not say whether the user has read it.
    public var completionIsBaseline: Bool? = nil
    public var isAncestorContext: Bool? = nil
    public var isSubagent: Bool? = nil
    public var nativeSidebarRank: Int? = nil
    public var nativeActivityAt: Date? = nil
    /// Local review/navigation time; never a source work or completion timestamp.
    public var lastViewedAt: Date? = nil
    var geminiConversation: GeminiConversationReference? = nil
    public var nativeSelected: Bool? = nil
    public var isChildSession: Bool { isSubagent == true || parentSessionId != nil }
    public var isAppActivity: Bool { statusSource == "desktop-window" }

    public var displayState: AgentState {

        if [.error, .stopped, .rateLimited, .working, .thinking, .starting, .waitingForApproval, .waitingForInput].contains(state) { return state }
        if needsInput { return .waitingForInput }
        if hasUnreadCompletion { return .completed }
        if state == .completed { return .idle }
        return state
    }

    public var displayTitle: String {
        guard let title = sessionTitle, !title.isEmpty else { return "Untitled" }
        return title
    }

    public var projectName: String {
        guard let path = projectPath, !path.isEmpty else { return nativeThreadID == nil && geminiConversation == nil && claudeDesktopID == nil ? "Unknown" : "\(agentType.displayName) Desktop" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Enum-style state name shown at the right of each row, matching the Windows app.
    public var displayStateName: String {
        if sourceUnread == true, [.unknown, .idle].contains(displayState) { return Localiz.current.string("State.UnreadMessages") }
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
        if geminiConversation != nil {
            let date = Localiz.current.string("Session.LastMessage") + " · " + lastActivityAt.formatted(date: .numeric, time: .standard)
            return state == .unknown ? date : displayStateName + " · " + date
        }
        if statusSource == "amp-agent-state" { return displayStateName }
        if isAppActivity { return Localiz.current.string("State.CurrentWindowWorking") }
        if sourceUnread == true { return Localiz.current.string("State.UnreadMessages") + " · " + (state == .working ? "Working" : Localiz.current.string("State.ExecutionUnavailable")) }
        if agentType == .amp, state == .unknown, let lastViewedAt { return Localiz.current.string("Session.LastViewed") + " · " + lastViewedAt.formatted(date: .numeric, time: .standard) + " · " + Localiz.current.string("State.ExecutionUnavailable") }
        if [.amp, .gemini].contains(agentType), state == .unknown { return Localiz.current.string("State.ExecutionUnavailable") }
        if let reset = rateLimitResetAt, displayState == .rateLimited {
            return HudTheme.formatPattern(
                Localiz.current.string("Session.RateLimitedReset"),
                [reset.formatted(date: .omitted, time: .shortened)]
            )
        }
        return displayStateName
    }
}
