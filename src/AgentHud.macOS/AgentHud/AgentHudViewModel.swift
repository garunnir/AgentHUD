import SwiftUI
import Combine

@MainActor
public final class AgentHudViewModel: ObservableObject {
    @Published public var sessions: [AgentSession] = []
    @Published public var isMinimized = false
    @Published public var hiddenSessionIds: Set<String> = []
    @Published public var memos: [String: String] = [:]
    // Codex active window (minutes). Sessions whose last event is within this window are considered active.
    @Published public var codexActiveWindowMinutes: Int = 60 {
        didSet { codexProvider.setActiveWindow(TimeInterval(codexActiveWindowMinutes * 60)) }
    }
    // Show waiting states as ? / ! symbols instead of yellow dots (off by default, like Windows).
    @Published public var showWaitingSymbols = false

    private let registry: AgentSessionRegistry
    private let discovery: AgentDiscoveryService
    private let codexProvider: CodexProvider
    private var updateTask: Task<Void, Never>?

    public init() {
        let registry = AgentSessionRegistry()
        self.registry = registry
        let home = NSHomeDirectory()
        let codex = CodexProvider(home: home, activeWindow: TimeInterval(60 * 60))
        self.codexProvider = codex
        let providers: [IAgentProvider] = [
            ClaudeCodeProvider(home: home),
            codex
        ]
        self.discovery = AgentDiscoveryService(providers: providers, registry: registry)

        registry.onChanged = { [weak self] in
            Task { @MainActor in self?.sessions = self?.registry.getAllAgents() ?? [] }
        }
    }

    public func start() {
        discovery.start()
    }

    public func stop() {
        discovery.stop()
    }

    public func toggleMinimized() {
        isMinimized.toggle()
    }

    public func hideSession(_ id: String) {
        hiddenSessionIds.insert(id)
    }

    public func showHiddenSessions() {
        hiddenSessionIds.removeAll()
    }

    public func acknowledgeCompletion(_ id: String) {
        registry.acknowledgeCompletion(id)
    }

    public func openProject(_ session: AgentSession) {
        guard let path = session.projectPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    public func setMemo(_ memo: String, for projectPath: String) {
        memos[projectPath] = memo
    }

    public func memo(for projectPath: String) -> String? {
        memos[projectPath]
    }

    // MARK: - Usage gauges

    /// Builds the bottom usage rows, mirroring the Windows UpdateUsage logic:
    /// Codex limits come from the latest session's rate_limits; Claude shows token totals.
    func buildUsageRows(now: Date = Date()) -> [UsageRow] {
        var rows: [UsageRow] = []
        let loc = Localiz.current

        let claude = sessions.filter { $0.agentType == .claudeCode }
        if !claude.isEmpty {
            let tokens5h = claude.reduce(Int64(0)) { $0 + $1.tokens5h }
            let tokensWeek = claude.reduce(Int64(0)) { $0 + $1.tokensWeek }
            rows.append(UsageRow(
                id: "claude-5h", agent: .claudeCode, label: "5h", usedPercent: nil,
                text: HudTheme.formatPattern(loc.string("Usage.Tokens"), [HudTheme.formatTokens(tokens5h)]),
                pacePercent: nil
            ))
            rows.append(UsageRow(
                id: "claude-week", agent: .claudeCode, label: "week", usedPercent: nil,
                text: HudTheme.formatPattern(loc.string("Usage.Tokens"), [HudTheme.formatTokens(tokensWeek)]),
                pacePercent: nil
            ))
        }

        if sessions.contains(where: { $0.agentType == .codex }) {
            let latest = sessions
                .filter { $0.agentType == .codex && $0.primaryLimit != nil }
                .max { $0.lastActivityAt < $1.lastActivityAt }
            if let latest, let primary = latest.primaryLimit {
                rows.append(codexRow(agent: .codex, label: "5h", window: primary, now: now))
                if let week = latest.secondaryLimit {
                    rows.append(codexRow(agent: .codex, label: "week", window: week, now: now))
                }
            } else {
                rows.append(UsageRow(
                    id: "codex-none", agent: .codex, label: "", usedPercent: nil,
                    text: loc.string("Usage.NoLimitInfo"), pacePercent: nil
                ))
            }
        }

        // Hide the 5h pace marker when weekly usage is already beyond its even pace.
        for index in rows.indices where rows[index].label == "5h" {
            let agent = rows[index].agent
            let weekBeyondPace = rows.contains { other in
                other.agent == agent && other.label == "week"
                    && (other.pacePercent.map { other.remainingPercent < $0 } ?? false)
            }
            if weekBeyondPace { rows[index].pacePercent = nil }
        }
        return rows
    }

    private func codexRow(agent: AgentType, label: String, window: LimitWindow, now: Date) -> UsageRow {
        let loc = Localiz.current
        let used = window.percentAt(now)
        let left = window.resetsAt.timeIntervalSince(now)
        var text = ""
        if left > 0 && left <= 8 * 86400 {
            if left >= 86400 {
                text = HudTheme.formatPattern(loc.string("Usage.ResetDays"), [left / 86400])
            } else {
                text = HudTheme.formatPattern(
                    loc.string("Usage.ResetHoursMinutes"),
                    [Int(left) / 3600, (Int(left) % 3600) / 60]
                )
            }
        }
        let length: TimeInterval = label == "5h" ? 5 * 3600 : 7 * 86400
        let pace: Double? = (left <= 0 || left > length) ? nil : left / length * 100
        return UsageRow(id: "\(agent.rawValue)-\(label)", agent: agent, label: label, usedPercent: used, text: text, pacePercent: pace)
    }
}
