import AppKit
import ApplicationServices

/// Positive unread survives a missed AX poll. Only a validated plain row clears it.
struct NativeUnreadMemory {
    private var values: [String: Bool] = [:]
    mutating func update(_ observations: [String: ThreadActivity], visibleIDs: Set<String>) {
        values = values.filter { visibleIDs.contains($0.key) }
        for (id, state) in observations where visibleIDs.contains(id) {
            if state == .unread { values[id] = true }
            else if state == .unknown { values[id] = false }
        }
    }
    func value(_ id: String) -> Bool? { values[id] }
}

/// Amp has stable URL IDs and an unread flag. Gemini exposes only temporary AX row identities.
/// Neither source's disappearing busy control is treated as successful completion.
final class NativeSidebarProvider: IAgentProvider {
    let agentType: AgentType
    let watchRoots: [String] = []
    private let app: AgentApp
    private let client: NativeSidebarClient
    private let poller = DesktopThreadPoller(.amp)
    private var rows: [ThreadItem] = []
    private var lastRunningAt: [String: Date] = [:]
    private var pid: pid_t?
    private var scannedAt = Date.distantPast
    private var lastSuccessfulScan = Date.distantPast
    private var unread = NativeUnreadMemory()
    private var signatures: [String: String] = [:]
    private var activityAt: [String: Date] = [:]
    private var changedAt: [String: Date] = [:]
    init(app: AgentApp, client: NativeSidebarClient) {
        precondition(app == .amp || app == .gemini)
        self.app = app; self.agentType = app == .amp ? .amp : .gemini; self.client = client
    }
    func discover() async throws -> [AgentSession] {
        guard AXIsProcessTrusted(), let bundle = app.bundleIDs.first,
              let process = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              !process.isTerminated else {
            rows = []; pid = nil; unread = NativeUnreadMemory(); signatures = [:]; changedAt = [:]; activityAt = [:]
            return []
        }
        let now = Date()
        if pid != process.processIdentifier || now.timeIntervalSince(scannedAt) >= 30 {
            if pid != process.processIdentifier { unread = NativeUnreadMemory(); signatures = [:]; changedAt = [:]; activityAt = [:] }
            if pid != process.processIdentifier { rows = []; lastSuccessfulScan = .distantPast }
            let scan = await client.scan(app: app, pid: process.processIdentifier)
            if scan.succeeded { rows = scan.threads; lastSuccessfulScan = now }


            pid = process.processIdentifier; scannedAt = now
        }
        if !Self.keepCachedRows(lastSuccess: lastSuccessfulScan, now: now) { rows = [] }
        if app == .gemini { return [] } // The history provider joins execution to stable chat IDs.
        let ids = Set(rows.map(\.id))
        lastRunningAt = lastRunningAt.filter { ids.contains($0.key) }
        signatures = signatures.filter { ids.contains($0.key) }
        changedAt = changedAt.filter { ids.contains($0.key) }
        activityAt = activityAt.filter { ids.contains($0.key) }
        let updates = await client.nativeActivityStates(app: app, pid: process.processIdentifier)
        unread.update(updates, visibleIDs: ids)
        let running = app == .amp ? await client.ampRunningSessionIDs(pid: process.processIdentifier) : []
        let requested = Set(rows.filter { !$0.isSubagent }.compactMap(\.activitySessionID))
        let remote = await poller.sample(Dictionary(uniqueKeysWithValues: requested.map { ($0, "") }), now: now)
        let sessions = rows.enumerated().map { rank, row in
            let isRunning = row.activitySessionID.map { running.contains($0) } ?? false
            let sourceUnread = app == .amp ? unread.value(row.id) : nil
            if isRunning { activityAt[row.id] = now; lastRunningAt[row.id] = now }
            let signature = "\(isRunning):\(sourceUnread.map(String.init) ?? "unobserved")"
            if signatures[row.id] != signature {
                if isRunning || (sourceUnread == true && signatures[row.id] == "false:false") { activityAt[row.id] = now }
                changedAt[row.id] = now; signatures[row.id] = signature
            }
            var session = makeSession(id: "desktop:\(row.id)", title: row.title, pid: process.processIdentifier,
                state: isRunning ? .working : .unknown, at: changedAt[row.id] ?? now)
            session.nativeThreadID = row.id; session.sourceUnread = sourceUnread
            session.nativeSidebarRank = rank; session.nativeSelected = row.selected
            session.nativeActivityAt = activityAt[row.id]; session.isSubagent = row.isSubagent
            session.isActive = isRunning || sourceUnread == true
            session.statusSource = "desktop-sidebar"
            if !isRunning, let id = row.activitySessionID, let report = remote[id], let seconds = report.at,
               seconds.isFinite, seconds > 0, seconds <= now.timeIntervalSince1970 + 5 {
                let at = Date(timeIntervalSince1970: seconds)
                // A native running observation wins until the server has caught up.
                if report.state != .completed || at >= (lastRunningAt[row.id] ?? .distantPast) {
                    session.state = report.state
                    session.statusSource = "amp-agent-state"
                    session.nativeActivityAt = max(session.nativeActivityAt ?? .distantPast, at)
                    session.lastActivityAt = at
                    session.isActive = report.state == .working || report.state == .waitingForApproval || sourceUnread == true
                    if report.state == .completed {
                        session.completionRevision = "amp-end:\(seconds)"
                        session.sourceRead = sourceUnread == false
                        session.completionIsBaseline = sourceUnread == nil && lastRunningAt[row.id] == nil
                    }
                }
            }
            return session
        }
        return sessions
    }
    static func keepCachedRows(lastSuccess: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(lastSuccess)
        return age >= 0 && age < 60
    }
    private func makeSession
(id: String, title: String, pid: pid_t, state: AgentState, at: Date) -> AgentSession {
        AgentSession(id: id, agentType: agentType, state: state, hasUnreadCompletion: false,
            completionDetectedAt: nil, processId: Int(pid), projectPath: nil, worktreePath: nil,
            sessionTitle: title, currentTask: nil, startedAt: at, lastActivityAt: at, isActive: false,
            wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: nil, rateLimitResetAt: nil,
            tokens5h: 0, tokensWeek: 0, primaryLimit: nil, secondaryLimit: nil)
    }
}
