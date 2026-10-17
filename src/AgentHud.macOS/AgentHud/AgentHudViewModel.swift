import SwiftUI
import Combine

@MainActor
public final class AgentHudViewModel: ObservableObject {
    @Published public var sessions: [AgentSession] = []
    @Published public var isMinimized = false
    @Published public var hiddenSessionIds: Set<String> = []
    @Published public var memos: [String: String] = [:]
    // Shared active window (minutes). Sessions whose last event is within this window are considered active.
    @Published public var activeWindowMinutes: Int = 60 {
        didSet {
            let seconds = TimeInterval(activeWindowMinutes * 60)
            codexProvider.setActiveWindow(seconds)
            claudeProvider.setActiveWindow(seconds)
            openCodeProvider.setActiveWindow(seconds)
            UserDefaults.standard.set(activeWindowMinutes, forKey: Self.activeWindowKey)
        }
    }
    // Show waiting states as ? / ! symbols instead of yellow dots (off by default, like Windows).
    @Published public var showWaitingSymbols = false
    /// Remaining-% the amber warning line marks in the usage bars (0 hides it).
    @Published public var warningPercent: Double = 30 {
        didSet { UserDefaults.standard.set(warningPercent, forKey: Self.warningPercentKey) }
    }
    /// White marker in the usage bars showing the even-pace position.
    @Published public var showPaceMarker: Bool = true {
        didSet { UserDefaults.standard.set(showPaceMarker, forKey: Self.paceMarkerKey) }
    }
    @Published public var conversationTarget: ConversationTarget = .visualStudioCode {
        didSet { UserDefaults.standard.set(conversationTarget.rawValue, forKey: Self.conversationTargetKey) }
    }
    /// True until the first discovery pass finishes, so the HUD can show a spinner
    /// instead of claiming there are no sessions.
    @Published public var isScanning = true
    /// Live Codex usage from the server (nil until the first successful fetch).
    @Published private(set) var liveUsage: CodexUsage?
    /// Live OpenCode Go usage from the Console (nil until Console login succeeds).
    @Published private(set) var openCodeGoUsage: OpenCodeGoUsage?
    /// True while the Console usage request is in flight, so the HUD does not look
    /// empty while a slow login/session request is still being resolved.
    @Published private(set) var isLoadingOpenCodeGoUsage = false
    @Published public var openCodeWorkspaceID: String = "" {
        didSet { UserDefaults.standard.set(openCodeWorkspaceID, forKey: Self.openCodeWorkspaceKey) }
    }
    /// Set by the `--render=` debug hook: drops the AppKit overlays, which paint a
    /// solid color over the view when it is rendered offscreen instead of in a window.
    public var isPreviewMode = false

    private var liveUsageFetchedAt: Date?
    private var liveUsageRetryAt: Date?
    private var liveUsageTask: Task<Void, Never>?
    private var openCodeGoTask: Task<Void, Never>?
    private var openCodeGoRetryAt: Date?
    /// Backoff after a failed fetch, so a blocked endpoint is not hit every cycle.
    private static let liveUsageFailureRetry: TimeInterval = 60
    /// Warning line default, also used when the stored value is missing.
    private static let defaultWarningPercent: Double = 30
    private static let warningPercentKey = "hud.warningPercent"
    private static let paceMarkerKey = "hud.paceMarker"
    private static let openCodeWorkspaceKey = "hud.openCodeWorkspaceID"
    private static let conversationTargetKey = "hud.conversationTarget"
    private static let activeWindowKey = "hud.activeWindowMinutes"

    private let registry: AgentSessionRegistry
    private let discovery: AgentDiscoveryService
    private let codexProvider: CodexProvider
    private let claudeProvider: ClaudeCodeProvider
    private let openCodeProvider: OpenCodeProvider
    private var updateTask: Task<Void, Never>?

    public init() {
        let registry = AgentSessionRegistry()
        self.registry = registry
        let home = NSHomeDirectory()
        let codex = CodexProvider(home: home, activeWindow: TimeInterval(60 * 60))
        self.codexProvider = codex
        let claude = ClaudeCodeProvider(home: home, activeWindow: TimeInterval(60 * 60))
        self.claudeProvider = claude
        let openCode = OpenCodeProvider(home: home, activeWindow: TimeInterval(60 * 60))
        self.openCodeProvider = openCode
        let providers: [IAgentProvider] = [
            claude,
            codex,
            openCode
        ]
        self.discovery = AgentDiscoveryService(providers: providers, registry: registry)

        registry.onChanged = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sessions = self.registry.getAllAgents()
                self.isScanning = false
            }
        }

        if let saved = UserDefaults.standard.object(forKey: Self.warningPercentKey) as? Double {
            self.warningPercent = saved
        } else {
            self.warningPercent = Self.defaultWarningPercent
        }
        if UserDefaults.standard.object(forKey: Self.paceMarkerKey) != nil {
            self.showPaceMarker = UserDefaults.standard.bool(forKey: Self.paceMarkerKey)
        }
        self.openCodeWorkspaceID = UserDefaults.standard.string(forKey: Self.openCodeWorkspaceKey) ?? ""
        if let savedWindow = UserDefaults.standard.object(forKey: Self.activeWindowKey) as? Int {
            self.activeWindowMinutes = max(1, savedWindow)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.conversationTargetKey),
           let target = ConversationTarget(rawValue: raw) {
            self.conversationTarget = target
        }
    }

    public func start() {
        discovery.start()
    }

    public func stop() {
        discovery.stop()
    }

    public func refreshOpenCodeGoUsage() {
        guard openCodeGoTask == nil else { return }
        if let retry = openCodeGoRetryAt, Date() < retry { return }
        isLoadingOpenCodeGoUsage = true
        openCodeGoTask = Task { [weak self] in
            defer {
                self?.openCodeGoTask = nil
                self?.isLoadingOpenCodeGoUsage = false
            }
            guard let self else { return }
            do {
                self.openCodeGoUsage = try await OpenCodeGoUsageApi.shared.fetch(
                    workspaceId: self.openCodeWorkspaceID
                )
                self.openCodeGoRetryAt = nil
            } catch {
                self.openCodeGoRetryAt = Date().addingTimeInterval(60)
                print("OpenCode Go usage API: \(error)")
            }
        }
    }

    public func openCodeGoCookiesSaved() {
        refreshOpenCodeGoUsage()
    }

    public func clearOpenCodeGoUsage() {
        openCodeGoUsage = nil
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
        guard let path = session.worktreePath ?? session.projectPath,
              FileManager.default.fileExists(atPath: path) else { return }
        switch conversationTarget {
        case .visualStudioCode:
            // Focus the project first, then hand the conversation URI to the extension.
            openInVSCode(path: path)
            guard let uri = conversationURI(for: session) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if let url = URL(string: uri) { NSWorkspace.shared.open(url) }
            }
        case .chatGPTDesktop:
            if session.agentType == .codex, let uri = chatGPTConversationURI(for: session) {
                NSWorkspace.shared.open(URL(string: uri)!)
            } else {
                openInDesktopApp(path: path, bundleIdentifiers: ["com.openai.codex"], fallback: "/Applications/ChatGPT.app")
            }
        case .openCodeDesktop:
            openInDesktopApp(path: path, bundleIdentifiers: ["ai.opencode.desktop"], fallback: "/Applications/OpenCode.app")
        case .claudeDesktop:
            openInDesktopApp(path: path, bundleIdentifiers: ["com.anthropic.claudefordesktop"], fallback: "/Applications/Claude.app")
        }
    }

    /// vscode:// URI that opens the conversation tab of the given session.
    private func conversationURI(for session: AgentSession) -> String? {
        // There is no confirmed OpenCode VS Code URI scheme yet. Still open the
        // project in VS Code, but do not send its session ID to the ChatGPT route.
        if session.agentType == .openCode { return nil }
        guard let separator = session.id.firstIndex(of: ":") else { return nil }
        let raw = String(session.id[session.id.index(after: separator)...])
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let escaped = raw.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return session.agentType == .claudeCode
            ? "vscode://anthropic.claude-code/open?session=\(escaped)"
            : "vscode://openai.chatgpt/local/\(escaped)"
    }

    private func chatGPTConversationURI(for session: AgentSession) -> String? {
        guard let separator = session.id.firstIndex(of: ":") else { return nil }
        let raw = String(session.id[session.id.index(after: separator)...])
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let escaped = raw.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "codex://threads/\(escaped)"
    }

    private func openInDesktopApp(path: String, bundleIdentifiers: [String], fallback: String) {
        let appURL = bundleIdentifiers
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first ?? URL(fileURLWithPath: fallback)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: appURL,
                                configuration: configuration)
    }

    /// Opens the project in VS Code. The `code` CLI is preferred so an existing window
    /// for the project is focused; a GUI app has a minimal PATH, so the usual install
    /// locations are checked before falling back to the app bundle.
    private func openInVSCode(path: String) {
        if let cli = locateCodeCLI() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = [path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { return }
        }
        let bundle = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        if FileManager.default.fileExists(atPath: bundle.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: bundle, configuration: configuration)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func locateCodeCLI() -> String? {
        let candidates = [
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            NSHomeDirectory() + "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Homebrew cask / manual installs expose `code` somewhere on the user's PATH,
        // which a GUI app does not inherit, so ask the login shell instead.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v code"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    public func setMemo(_ memo: String, for projectPath: String) {
        memos[projectPath] = memo
    }

    public func memo(for projectPath: String) -> String? {
        memos[projectPath]
    }

    /// Fetches live usage from the server at most every 5 minutes (failures retry after
    /// 1 minute). Failures are swallowed so the local-log fallback keeps the gauge working.
    private func refreshLiveUsageIfNeeded(now: Date) {
        guard liveUsageTask == nil else { return }
        if let next = liveUsageRetryAt {
            if now < next { return }
        } else if let fetched = liveUsageFetchedAt,
                  now.timeIntervalSince(fetched) < CodexUsageApi.refreshInterval {
            return
        }
        liveUsageTask = Task { [weak self] in
            defer { self?.liveUsageTask = nil }
            guard let self else { return }
            do {
                let usage = try await CodexUsageApi.shared.fetchUsage()
                self.liveUsageFetchedAt = Date()
                self.liveUsageRetryAt = nil
                self.liveUsage = usage
            } catch {
                // Keep the previous value/fallback; back off before retrying.
                print("Codex usage API: \(error)")
                self.liveUsageRetryAt = Date().addingTimeInterval(Self.liveUsageFailureRetry)
            }
        }
    }

    // MARK: - Usage gauges

    /// Builds the bottom usage rows, mirroring the Windows UpdateUsage logic:
    /// Codex limits come from the latest session's rate_limits; Claude shows token totals.
    func buildUsageRows(now: Date = Date()) -> [UsageRow] {
        refreshLiveUsageIfNeeded(now: now)
        if OpenCodeGoUsageApi.shared.hasCookies,
           openCodeGoUsage == nil || now.timeIntervalSince(openCodeGoUsage!.fetchedAt) >= OpenCodeGoUsageApi.refreshInterval {
            refreshOpenCodeGoUsage()
        }
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

        // Live server data wins; local logs only fill in when the API is unavailable.
        let live = liveUsage
        if live?.primary != nil {
            rows.append(codexRow(agent: .codex, label: "5h", window: live!.primary!,
                                 updatedAt: liveUsageFetchedAt, now: now, fromServer: true))
            if let week = live?.secondary {
                rows.append(codexRow(agent: .codex, label: "week", window: week,
                                     updatedAt: liveUsageFetchedAt, now: now, fromServer: true))
            }
        } else if sessions.contains(where: { $0.agentType == .codex }) {
            // Limits are account-wide, so use the session with the freshest snapshot.
            // Picking the most recently *active* session can show stale numbers when
            // that session's last token_count predates another session's.
            let latest = sessions
                .filter { $0.agentType == .codex && $0.primaryLimit != nil }
                .max { lhs, rhs in
                    switch (lhs.limitsUpdatedAt, rhs.limitsUpdatedAt) {
                    case let (left?, right?): return left < right
                    case (nil, _?): return true
                    case (_?, nil): return false
                    default: return lhs.lastActivityAt < rhs.lastActivityAt
                    }
                }
            if let latest, let primary = latest.primaryLimit {
                rows.append(codexRow(agent: .codex, label: "5h", window: primary,
                                     updatedAt: latest.limitsUpdatedAt, now: now))
                if let week = latest.secondaryLimit {
                    rows.append(codexRow(agent: .codex, label: "week", window: week,
                                         updatedAt: latest.limitsUpdatedAt, now: now))
                }
            } else {
                rows.append(UsageRow(
                    id: "codex-none", agent: .codex, label: "", usedPercent: nil,
                    text: loc.string("Usage.NoLimitInfo"), pacePercent: nil
                ))
            }
        }

        if let go = openCodeGoUsage {
            rows.append(codexRow(agent: .openCodeGo, label: "5h", window: go.fiveHour,
                                 updatedAt: go.fetchedAt, now: now, fromServer: true))
            rows.append(codexRow(agent: .openCodeGo, label: "week", window: go.week,
                                 updatedAt: go.fetchedAt, now: now, fromServer: true))
            rows.append(codexRow(agent: .openCodeGo, label: "month", window: go.month,
                                 updatedAt: go.fetchedAt, now: now, fromServer: true))
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
        if !showPaceMarker {
            for index in rows.indices { rows[index].pacePercent = nil }
        }
        return rows
    }

    private func codexRow(agent: AgentType, label: String, window: LimitWindow,
                          updatedAt: Date? = nil, now: Date,
                          fromServer: Bool = false) -> UsageRow {
        let loc = Localiz.current
        let used = window.percentAt(now)
        let left = window.resetsAt?.timeIntervalSince(now) ?? 0
        var text = ""
        if left > 0 && left <= 31 * 86400 {
            if left >= 86400 {
                text = HudTheme.formatPattern(loc.string("Usage.ResetDays"), [left / 86400])
            } else {
                text = HudTheme.formatPattern(
                    loc.string("Usage.ResetHoursMinutes"),
                    [Int(left) / 3600, (Int(left) % 3600) / 60]
                )
            }
        }
        // Prefer the server-reported window length; fall back to the usual 5 h / 7 day windows.
        let fallbackMinutes = label == "5h" ? 5 * 60 : 7 * 24 * 60
        let length = TimeInterval(window.windowMinutes ?? fallbackMinutes) * 60
        let pace: Double? = (left <= 0 || left > length) ? nil : left / length * 100
        return UsageRow(id: "\(agent.rawValue)-\(label)", agent: agent, label: label,
                        usedPercent: used, text: text, pacePercent: pace, updatedAt: updatedAt,
                        fromServer: fromServer, warningPercent: warningPercent)
    }

    // MARK: - Debug render hook

    /// Sample data for `AgentHud --render=mini|full`, which exports a preview PNG
    /// without showing a window. Not used by the running app.
    func installPreviewSessions() {
        let now = Date()
        isScanning = false
        sessions = [
            AgentSession(
                id: "claude:preview-1", agentType: .claudeCode, state: .working,
                hasUnreadCompletion: false, completionDetectedAt: nil, processId: 4242,
                projectPath: "/Users/hail/Documents/GitHub/AgentHud",
                worktreePath: nil, sessionTitle: "Port the HUD to macOS",
                currentTask: nil, startedAt: now.addingTimeInterval(-3600),
                lastActivityAt: now.addingTimeInterval(-20), isActive: true,
                wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: nil,
                rateLimitResetAt: nil, tokens5h: 12_400_000, tokensWeek: 61_800_000,
                primaryLimit: nil, secondaryLimit: nil, limitsUpdatedAt: nil
            ),
            AgentSession(
                id: "codex:preview-2", agentType: .codex, state: .rateLimited,
                hasUnreadCompletion: false, completionDetectedAt: nil, processId: nil,
                projectPath: "/Users/hail/Documents/GitHub/AgentHud",
                worktreePath: nil, sessionTitle: "Usage gauge accuracy",
                currentTask: nil, startedAt: now.addingTimeInterval(-7200),
                lastActivityAt: now.addingTimeInterval(-90), isActive: true,
                wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: nil,
                rateLimitResetAt: now.addingTimeInterval(8416),
                tokens5h: 0, tokensWeek: 0,
                primaryLimit: LimitWindow(usedPercent: 100,
                                          resetsAt: now.addingTimeInterval(8416),
                                          windowMinutes: 300),
                secondaryLimit: LimitWindow(usedPercent: 20,
                                            resetsAt: Date(timeIntervalSince1970: 1_792_296_526),
                                            windowMinutes: 10_080),
                limitsUpdatedAt: now
            ),
            AgentSession(
                id: "codex:preview-3", agentType: .codex, state: .waitingForInput,
                hasUnreadCompletion: false, completionDetectedAt: nil, processId: nil,
                projectPath: "/Users/hail/Documents/GitHub/Notes",
                worktreePath: nil, sessionTitle: "Weekly digest",
                currentTask: nil, startedAt: now.addingTimeInterval(-5400),
                lastActivityAt: now.addingTimeInterval(-240), isActive: true,
                wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: nil,
                rateLimitResetAt: nil,
                tokens5h: 0, tokensWeek: 0,
                primaryLimit: nil, secondaryLimit: nil, limitsUpdatedAt: nil
            )
        ]
    }
}
