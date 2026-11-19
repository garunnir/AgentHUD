import SwiftUI
import Combine
import ApplicationServices

@MainActor
public final class AgentHudViewModel: ObservableObject {
    @Published public var sessions: [AgentSession] = []
    @Published public var isMinimized = false
    /// Hidden session ID → display state when last seen. A hidden session comes back once it
    /// newly needs attention (waiting or completed), like on Windows.
    @Published public private(set) var hiddenSessions: [String: AgentState] = [:]
    public var hiddenSessionIds: Set<String> { Set(hiddenSessions.keys) }
    /// Bumped on every memo save so rows re-read their memo icon.
    @Published public private(set) var memoVersion = 0
    // Shared active window (minutes). Sessions whose last event is within this window are considered active.
    @Published public var activeWindowMinutes: Int = 60 {
        didSet {
            let seconds = TimeInterval(activeWindowMinutes * 60)
            codexProvider.setActiveWindow(seconds)
            claudeProvider.setActiveWindow(seconds)
            claudeDesktopProvider.activeWindow = seconds
            openCodeProvider.setActiveWindow(seconds)
            UserDefaults.standard.set(activeWindowMinutes, forKey: Self.activeWindowKey)
        }
    }
    /// Display language code; `Localiz.auto` follows the system language.
    @Published public var uiLanguage: String = Localiz.auto {
        didSet {
            Localiz.current.language = uiLanguage
            UserDefaults.standard.set(uiLanguage, forKey: Self.languageKey)
        }
    }
    /// Resume a conversation once via the CLI after its usage limit resets (see AutoResumer).
    @Published public var autoResume = false {
        didSet { UserDefaults.standard.set(autoResume, forKey: Self.autoResumeKey) }
    }
    /// Custom resume message; empty means the current language's default.
    @Published public var resumePrompt = "" {
        didSet { UserDefaults.standard.set(resumePrompt, forKey: Self.resumePromptKey) }
    }
    @Published public var notifyLimitReset = true {
        didSet {
            UserDefaults.standard.set(notifyLimitReset, forKey: Self.notifyLimitResetKey)
            if notifyLimitReset { notifications.requestAuthorization() }
        }
    }
    /// Skip hidden sessions when announcing a limit reset.
    @Published public var notifyVisibleOnly = true {
        didSet { UserDefaults.standard.set(notifyVisibleOnly, forKey: Self.notifyVisibleOnlyKey) }
    }
    @Published public var completeSoundEnabled = true {
        didSet { UserDefaults.standard.set(completeSoundEnabled, forKey: Self.completeSoundEnabledKey) }
    }
    @Published public var completeSound = "Glass" {
        didSet { UserDefaults.standard.set(completeSound, forKey: Self.completeSoundKey) }
    }
    @Published public var completeSoundFile = "" {
        didSet { UserDefaults.standard.set(completeSoundFile, forKey: Self.completeSoundFileKey) }
    }
    @Published public var askSoundEnabled = true {
        didSet { UserDefaults.standard.set(askSoundEnabled, forKey: Self.askSoundEnabledKey) }
    }
    @Published public var askSound = "Ping" {
        didSet { UserDefaults.standard.set(askSound, forKey: Self.askSoundKey) }
    }
    @Published public var askSoundFile = "" {
        didSet { UserDefaults.standard.set(askSoundFile, forKey: Self.askSoundFileKey) }
    }
    /// Claude token budgets (million tokens) used when no real limit is known; 0 = total only.
    @Published public var claudeBudget5h: Double = 0 {
        didSet { UserDefaults.standard.set(claudeBudget5h, forKey: Self.claudeBudget5hKey) }
    }
    @Published public var claudeBudgetWeek: Double = 0 {
        didSet { UserDefaults.standard.set(claudeBudgetWeek, forKey: Self.claudeBudgetWeekKey) }
    }
    /// Remaining-% the amber warning line marks in the usage bars (0 hides it).
    @Published public var warningPercent: Double = 30 {
        didSet { UserDefaults.standard.set(warningPercent, forKey: Self.warningPercentKey) }
    }
    /// White marker in the usage bars showing the even-pace position.
    @Published public var showPaceMarker: Bool = true {
        didSet { UserDefaults.standard.set(showPaceMarker, forKey: Self.paceMarkerKey) }
    }
    @Published public var conversationTarget: ConversationTarget = .automatic {
        didSet { UserDefaults.standard.set(conversationTarget.rawValue, forKey: Self.conversationTargetKey) }
    }
    /// Registers/unregisters the Claude Code statusLine link (default on; see ClaudeLimitLink).
    @Published public var claudeLimitLinked: Bool = false {
        didSet {
            UserDefaults.standard.set(claudeLimitLinked, forKey: Self.claudeLinkKey)
            guard claudeLimitLinked != ClaudeLimitLink.shared.isLinked else { return }
            do { if claudeLimitLinked { try ClaudeLimitLink.shared.link() } else { try ClaudeLimitLink.shared.unlink() } }
            catch {
                // Tell the user (like Windows) and show the actual link state again.
                let alert = NSAlert()
                alert.messageText = Localiz.current.string("Error.ClaudeLinkFailed")
                alert.informativeText = error.localizedDescription
                DispatchQueue.main.async { alert.runModal() }
                claudeLimitLinked = ClaudeLimitLink.shared.isLinked
                UserDefaults.standard.set(claudeLimitLinked, forKey: Self.claudeLinkKey)
            }
        }
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
    private static let claudeLinkKey = "hud.claudeLimitLink"
    private static let languageKey = "hud.language"
    private static let autoResumeKey = "hud.autoResume"
    private static let resumePromptKey = "hud.resumePrompt"
    private static let notifyLimitResetKey = "hud.notifyLimitReset"
    private static let notifyVisibleOnlyKey = "hud.notifyVisibleOnly"
    private static let completeSoundEnabledKey = "hud.completeSoundEnabled"
    private static let completeSoundKey = "hud.completeSound"
    private static let completeSoundFileKey = "hud.completeSoundFile"
    private static let askSoundEnabledKey = "hud.askSoundEnabled"
    private static let askSoundKey = "hud.askSound"
    private static let askSoundFileKey = "hud.askSoundFile"
    private static let claudeBudget5hKey = "hud.claudeBudget5h"
    private static let claudeBudgetWeekKey = "hud.claudeBudgetWeek"
    /// ~/Library/Application Support/AgentHud (memos.json, auto-resume.log).
    static let dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentHud")

    private let resumer: AutoResumer
    private let limitNotifier = RateLimitNotifier()
    private let notifications: LimitResetNotifications
    private let memoStore: MemoStore
    /// Display state per session at the previous scan; sounds play only on a change.
    private var lastStates: [String: AgentState] = [:]
    private var soundsPrimed = false

    @Published public private(set) var selectedSessionID: String?
    @Published public private(set) var openingMessage: String?
    @Published public private(set) var isOpening = false
    let claudeWebUsage = ClaudeWebKitUsage()
    let ampWebUsage = BackgroundUsageService<AmpUsagePage>()
    private var ampUsageObserver: AnyCancellable?
    private var claudeUsageObserver: AnyCancellable?
    private let nativeClient = NativeSidebarClient()
    private lazy var router = ConversationRouter(native: nativeClient)
    private let registry: AgentSessionRegistry
    private let discovery: AgentDiscoveryService
    private let codexProvider: CodexProvider
    private let claudeDesktopProvider: ClaudeDesktopMetadataProvider
    private let claudeProvider: ClaudeCodeProvider
    private let openCodeProvider: OpenCodeProvider
    private var updateTask: Task<Void, Never>?

    public init(previewMode: Bool = false) {
        let dataDirectory = previewMode ? FileManager.default.temporaryDirectory.appendingPathComponent("AgentHud-preview-\(UUID())") : Self.dataDirectory
        self.resumer = AutoResumer(logDirectory: dataDirectory)
        self.notifications = LimitResetNotifications()
        self.memoStore = MemoStore(url: dataDirectory.appendingPathComponent("memos.json"))
        let registry = AgentSessionRegistry(storageURL: previewMode ? nil : dataDirectory.appendingPathComponent("completion-state.json"))
        self.registry = registry
        let home = NSHomeDirectory()
        let codex = CodexProvider(home: home, activeWindow: TimeInterval(60 * 60), retainedParentIDs: { registry.getByAgentType(.codex).filter(\.hasUnreadCompletion).compactMap(\.parentSessionId) })
        self.codexProvider = codex
        let claude = ClaudeCodeProvider(home: home, activeWindow: TimeInterval(60 * 60))
        self.claudeProvider = claude
        claudeDesktopProvider = ClaudeDesktopMetadataProvider(home: home, client: nativeClient)
        let openCode = OpenCodeProvider(home: home, activeWindow: TimeInterval(60 * 60), retainedParentIDs: { registry.getByAgentType(.openCode).filter(\.hasUnreadCompletion).compactMap(\.parentSessionId) })
        self.openCodeProvider = openCode
        let providers: [IAgentProvider] = [
            claude,
            codex,
            openCode,
            claudeDesktopProvider,
            NativeSidebarProvider(app: .amp, client: nativeClient),
            NativeSidebarProvider(app: .gemini, client: nativeClient),
            GeminiHistoryProvider(home: home, native: nativeClient)
        ]
        self.discovery = AgentDiscoveryService(providers: providers, registry: registry, activity: LiveActivityOverlay(roots: LiveActivityOverlay.defaultRoots(home: URL(fileURLWithPath: home))))

        registry.onChanged = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sessionsChanged(self.registry.getAllAgents())
            }
        }

        if previewMode { isPreviewMode = true; return }

        ampUsageObserver = ampWebUsage.$snapshot.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
        claudeUsageObserver = claudeWebUsage.$snapshot.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }

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
        // Migration: first run / upgrade with no stored choice links the statusLine once,
        // silently. `didSet` does not fire for assignments made inside this initializer,
        // so the persisted key and the actual link/unlink call are both done explicitly
        // here instead of relying on the `claudeLimitLinked` property observer. A failed
        // install leaves the key unset so it retries next launch instead of being stuck
        // "declined".
        if UserDefaults.standard.object(forKey: Self.claudeLinkKey) == nil {
            if ClaudeLimitLink.shared.linkQuietly() || ClaudeLimitLink.shared.isLinked {
                self.claudeLimitLinked = true
                UserDefaults.standard.set(true, forKey: Self.claudeLinkKey)
            }
        } else {
            let linked = UserDefaults.standard.bool(forKey: Self.claudeLinkKey)
            self.claudeLimitLinked = linked
            if linked && !ClaudeLimitLink.shared.isLinked {
                ClaudeLimitLink.shared.linkQuietly()
            }
        }
        // Settings ported from Windows. `didSet` does not run inside init, so side effects
        // (language, notification permission) are applied explicitly below.
        let defaults = UserDefaults.standard
        self.uiLanguage = defaults.string(forKey: Self.languageKey) ?? Localiz.auto
        Localiz.current.language = self.uiLanguage
        self.autoResume = defaults.bool(forKey: Self.autoResumeKey)
        self.resumePrompt = defaults.string(forKey: Self.resumePromptKey) ?? ""
        self.notifyLimitReset = defaults.object(forKey: Self.notifyLimitResetKey) as? Bool ?? true
        self.notifyVisibleOnly = defaults.object(forKey: Self.notifyVisibleOnlyKey) as? Bool ?? true
        self.completeSoundEnabled = defaults.object(forKey: Self.completeSoundEnabledKey) as? Bool ?? true
        self.completeSound = defaults.string(forKey: Self.completeSoundKey) ?? "Glass"
        self.completeSoundFile = defaults.string(forKey: Self.completeSoundFileKey) ?? ""
        self.askSoundEnabled = defaults.object(forKey: Self.askSoundEnabledKey) as? Bool ?? true
        self.askSound = defaults.string(forKey: Self.askSoundKey) ?? "Ping"
        self.askSoundFile = defaults.string(forKey: Self.askSoundFileKey) ?? ""
        self.claudeBudget5h = max(0, defaults.double(forKey: Self.claudeBudget5hKey))
        self.claudeBudgetWeek = max(0, defaults.double(forKey: Self.claudeBudgetWeekKey))
        notifications.onOpen = { [weak self] id in self?.openSession(id) }
        if notifyLimitReset { notifications.requestAuthorization() }
    }

    // MARK: - Session updates (sounds, hidden sessions, limit reset, auto-resume)

    private func sessionsChanged(_ all: [AgentSession]) {
        if autoResume {
            // CLI lookup may ask the login shell, so keep it off the main thread.
            let resumer = self.resumer
            let prompt = resumePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AutoResumer.defaultPrompt : resumePrompt
            DispatchQueue.global(qos: .utility).async { resumer.check(all, prompt: prompt) }
        }
        playStateSounds(all)
        // Keep hidden sessions hidden until reset, but show one again once it newly waits or completes.
        var hidden = hiddenSessions
        for (id, seen) in hiddenSessions {
            guard let session = all.first(where: { $0.id == id }) else { hidden[id] = nil; continue }
            let state = session.displayState
            let unreadArrived = session.sourceUnread == true && sessions.first(where: { $0.id == id })?.sourceUnread != true
            hidden[id] = unreadArrived || (state != seen && Self.needsAttention(state)) ? nil : state
        }
        if hidden != hiddenSessions { hiddenSessions = hidden }
        if let selected = selectedSessionID, !all.contains(where: { $0.id == selected }),
           let nativeID = sessions.first(where: { $0.id == selected })?.nativeThreadID,
           let merged = all.first(where: { $0.nativeThreadID == nativeID }) { selectedSessionID = merged.id }
        sessions = all
        isScanning = false
        if notifyLimitReset {
            let visibleIDs = Set(SessionListPolicy.rows(all, hidden: Set(hidden.keys), activeWindow: TimeInterval(activeWindowMinutes * 60)).map(\.id))
            let candidates = notifyVisibleOnly ? all.filter { visibleIDs.contains($0.id) } : all
            for session in limitNotifier.takeDue(candidates) { showLimitReset(session) }
        }
    }

    private static func needsAttention(_ state: AgentState) -> Bool {
        state == .waitingForInput || state == .waitingForApproval || state == .completed
    }

    private func playStateSounds(_ all: [AgentSession]) {
        var complete = false, ask = false
        let now = Date()
        for session in all {
            let state = session.displayState
            let previous = lastStates[session.id]
            lastStates[session.id] = state
            // Skip the first scan and old sessions discovered late.
            if !soundsPrimed || previous == state || session.isChildSession
                || now.timeIntervalSince(session.lastActivityAt) > 60 { continue }
            if state == .completed { complete = true }
            else if state == .waitingForInput || state == .waitingForApproval { ask = true }
        }
        let seen = Set(all.map(\.id))
        lastStates = lastStates.filter { seen.contains($0.key) }
        soundsPrimed = true
        if ask && askSoundEnabled { SoundPlayer.play(askSound, file: askSoundFile) }
        else if complete && completeSoundEnabled { SoundPlayer.play(completeSound, file: completeSoundFile) }
    }

    private func showLimitReset(_ session: AgentSession) {
        let loc = Localiz.current
        let time = session.rateLimitResetAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        let title = HudTheme.formatPattern(loc.string("Notify.LimitResetTitle"), [session.agentType.displayName, session.projectName])
        let body = HudTheme.formatPattern(loc.string("Notify.LimitResetBody").replacingOccurrences(of: "{1:HH:mm}", with: "{1}"),
                                          [session.displayTitle, time])
            + " " + loc.string(autoResume ? "Notify.AutoResumeSoon" : "Notify.ClickToOpen")
        notifications.show(sessionId: session.id, title: title, body: body)
    }

    private func openSession(_ id: String) {
        guard let session = registry.findSession(id) else { return }
        openProject(session)
    }

    public func previewSound(ask: Bool) {
        if ask { SoundPlayer.play(askSound, file: askSoundFile) }
        else { SoundPlayer.play(completeSound, file: completeSoundFile) }
    }

    public func start() {
        if !isPreviewMode {
            claudeWebUsage.start()
            ampWebUsage.start()
        }
        discovery.start()
    }

    public func stop() {
        ampWebUsage.stop()
        claudeWebUsage.stop()
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
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        // Acknowledge a completion so the hidden row does not pop right back.
        hiddenSessions[id] = session.hasUnreadCompletion ? .idle : session.displayState
        if session.hasUnreadCompletion { registry.acknowledgeCompletion(id, revision: registry.findSession(id)?.completionRevision) }
    }

    public func showHiddenSessions() {
        hiddenSessions.removeAll()
    }

    public func acknowledgeCompletion(_ id: String) {
        registry.acknowledgeCompletion(id, revision: registry.findSession(id)?.completionRevision)
    }

    public func openProject(_ session: AgentSession) {
        guard !isOpening else { return }
        let revision = session.completionRevision
        isOpening = true; openingMessage = nil
        Task {
            defer { isOpening = false }
            let result = await router.open(session, preference: conversationTarget)
            registry.recordNavigation(session.id, result: result)
            if result.acknowledgesCompletion {
                selectedSessionID = session.id
                registry.acknowledgeCompletion(session.id, revision: revision)
            }
            switch result {
            case .failed: openingMessage = Localiz.current.string("Navigation.Failed")
            case .projectOnly: openingMessage = Localiz.current.string("Navigation.ProjectOnly")
            case .extensionRequested: openingMessage = Localiz.current.string("Navigation.ExtensionRequested")
            default: break
            }
        }
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Memos

    public var globalMemo: String { memoStore.global }

    public func setGlobalMemo(_ text: String) {
        memoStore.setGlobal(text)
        memoVersion += 1
    }

    public func projectMemo(_ projectPath: String?) -> String { memoStore.project(projectPath) ?? "" }

    public func hasProjectMemo(_ projectPath: String?) -> Bool { memoStore.hasProject(projectPath) }

    public func setProjectMemo(_ projectPath: String, _ text: String) {
        memoStore.setProject(projectPath, text)
        memoVersion += 1
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
        guard !isPreviewMode else { return [] }
        refreshLiveUsageIfNeeded(now: now)
        if OpenCodeGoUsageApi.shared.hasCookies,
           openCodeGoUsage == nil || now.timeIntervalSince(openCodeGoUsage!.fetchedAt) >= OpenCodeGoUsageApi.refreshInterval {
            refreshOpenCodeGoUsage()
        }
        var rows: [UsageRow] = []
        let loc = Localiz.current

        let claude = sessions.filter { $0.agentType == .claudeCode && $0.id.hasPrefix("claude:") }
        let web = claudeWebUsage.snapshot ?? .none
        if !claude.isEmpty || web.hasData {
            let lastActivity = claude.map(\.lastActivityAt).max()
            let local: ClaudeLimitSnapshot = web.hasData ? .none : ClaudeLimitLink.shared.readSnapshot()
            let pick = ClaudeLimitPolicy.pick(statusLine: local, api: web,
                                              now: now, lastClaudeActivity: lastActivity)
            let tokensWeek = claude.reduce(Int64(0)) { $0 + $1.tokensWeek }
            if pick.showsFiveHour(at: now, tokenBudget: claudeBudget5h) {
                let tokens5h = claude.reduce(Int64(0)) { $0 + $1.tokens5h }
                rows.append(claudeLimitRow(id: "claude-5h", label: "5h", window: pick.fiveHour, stale: pick.fiveHourStale,
                                           pickUpdatedAt: pick.updatedAt, source: pick.source, tokens: tokens5h, now: now))
            }
            rows.append(claudeLimitRow(id: "claude-week", label: "week", window: pick.sevenDay, stale: pick.sevenDayStale,
                                       pickUpdatedAt: pick.updatedAt, source: pick.source, tokens: tokensWeek, now: now))
        }

        // Live server data wins; local logs only fill in when the API is unavailable.
        if let live = liveUsage {
            for (label, window) in CodexUsage.displayWindows(primary: live.primary, secondary: live.secondary) {
                rows.append(codexRow(agent: .codex, label: label, window: window,
                                     updatedAt: liveUsageFetchedAt, now: now, fromServer: true))
            }
        } else if sessions.contains(where: { $0.agentType == .codex }) {
            // Limits are account-wide, so use the session with the freshest snapshot.
            // Picking the most recently *active* session can show stale numbers when
            // that session's last token_count predates another session's.
            let latest = sessions
                .filter { $0.agentType == .codex && ($0.primaryLimit != nil || $0.secondaryLimit != nil) }
                .max { lhs, rhs in
                    switch (lhs.limitsUpdatedAt, rhs.limitsUpdatedAt) {
                    case let (left?, right?): return left < right
                    case (nil, _?): return true
                    case (_?, nil): return false
                    default: return lhs.lastActivityAt < rhs.lastActivityAt
                    }
                }
            if let latest {
                for (label, window) in CodexUsage.displayWindows(primary: latest.primaryLimit, secondary: latest.secondaryLimit) {
                    rows.append(codexRow(agent: .codex, label: label, window: window,
                                         updatedAt: latest.limitsUpdatedAt, now: now))
                }
            } else {
                rows.append(UsageRow(
                    id: "codex-none", agent: .codex, label: "", usedPercent: nil,
                    text: loc.string("Usage.NoLimitInfo"), pacePercent: nil
                ))
            }
        }

        if let amp = ampWebUsage.snapshot, amp.reset > now {
            for (label, allowance) in [("Agent", amp.agent), ("Orb", amp.orb)] {
                let window = LimitWindow(usedPercent: 100 - allowance.value, resetsAt: amp.reset)
                var row = codexRow(agent: .amp, label: label, window: window, updatedAt: amp.observed,
                                   now: now, fromServer: now.timeIntervalSince(amp.observed) < 300)
                row.remainingLabel = allowance.label
                if allowance.value <= warningPercent && !allowance.indicatesLowBalance(at: warningPercent) { row.warningPercent = 0 }
                row.pacePercent = nil
                rows.append(row)
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

    /// No window (neither source has data) falls back to the token-budget estimate; a stale
    /// window shows the last known value marked "Stale" (or, once that window's `resetsAt`
    /// has passed and the number is meaningless, just "Stale"); otherwise a real gauge.
    private func claudeLimitRow(id: String, label: String, window: LimitWindow?, stale: Bool,
                                 pickUpdatedAt: Date, source: ClaudeLimitSource, tokens: Int64, now: Date) -> UsageRow {
        let loc = Localiz.current
        guard let window else {
            // No real limit: compare against the user's token budget, or show only the total.
            let budget = label == "5h" ? claudeBudget5h : claudeBudgetWeek
            guard budget > 0 else {
                return UsageRow(id: id, agent: .claudeCode, label: label, usedPercent: nil,
                                text: HudTheme.formatPattern(loc.string("Usage.Tokens"), [HudTheme.formatTokens(tokens)]),
                                pacePercent: nil)
            }
            let used = min(100, Double(tokens) / (budget * 1_000_000) * 100)
            return UsageRow(id: id, agent: .claudeCode, label: label, usedPercent: used,
                            text: "\(HudTheme.formatTokens(tokens))/\(HudTheme.formatPattern("{0:0.#}", [budget]))M",
                            pacePercent: nil, warningPercent: warningPercent)
        }
        if stale {
            let expired = window.resetsAt.map { $0 <= now } ?? false
            let text = expired ? loc.string("Usage.Stale")
                : HudTheme.formatPattern(loc.string("Usage.StaleValue"), [window.usedPercent])
            let tip = HudTheme.formatPattern(loc.string(source == .usageApi ? "Usage.ClaudeWebStaleTip" : "Usage.StaleTip"), [pickUpdatedAt])
            return UsageRow(id: id, agent: .claudeCode, label: label, usedPercent: nil,
                            text: text, pacePercent: nil, textToolTip: tip)
        }
        return codexRow(agent: .claudeCode, label: label, window: window, updatedAt: pickUpdatedAt, now: now, fromServer: source == .usageApi)
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
        sessions[0].needsInput = true
        var completed = sessions[2]
        completed = AgentSession(id: "codex:preview-4", agentType: .codex, state: .completed,
            hasUnreadCompletion: true, completionDetectedAt: now, processId: nil, projectPath: "/fixture/AgentHud",
            worktreePath: nil, sessionTitle: "Result ready to review", currentTask: nil, startedAt: now,
            lastActivityAt: now, isActive: false, wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: nil,
            rateLimitResetAt: nil, tokens5h: 0, tokensWeek: 0, primaryLimit: nil, secondaryLimit: nil)
        sessions.append(completed)
        selectedSessionID = sessions[0].id
    }
}
