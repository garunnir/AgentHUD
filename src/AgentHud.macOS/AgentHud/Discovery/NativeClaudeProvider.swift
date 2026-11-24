import AppKit
import ApplicationServices

/// Desktop rows have their own identity until a canonical log UUID mapping is proven.
/// Never merge them by title with CLI/extension sessions.
final class NativeClaudeProvider: IAgentProvider {
    let agentType: AgentType = .claudeCode
    let watchRoots: [String] = []
    private let client: NativeSidebarClient
    private var rows: [ThreadItem] = []
    private var pid: pid_t?
    private var scannedAt = Date.distantPast
    private var states: [String: ThreadActivity] = [:]
    private var activityAt: [String: Date] = [:]
    private var changedAt: [String: Date] = [:]
    private var revisions: [String: String] = [:]
    init(client: NativeSidebarClient) { self.client = client }
    func discover() async throws -> [AgentSession] {
        guard AXIsProcessTrusted(), let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first,
              !process.isTerminated else { rows = []; pid = nil; return [] }
        if process.processIdentifier != pid || Date().timeIntervalSince(scannedAt) >= 30 {
            rows = await client.scan(app: .claude, pid: process.processIdentifier).threads
            pid = process.processIdentifier; scannedAt = Date()
            let ids = Set(rows.map(\.id))
            states = states.filter { ids.contains($0.key) }; revisions = revisions.filter { ids.contains($0.key) }
            changedAt = changedAt.filter { ids.contains($0.key) }
            activityAt = activityAt.filter { ids.contains($0.key) }
        }
        let updates = await client.nativeActivityStates(app: .claude, pid: process.processIdentifier)
        let now = Date()
        return rows.enumerated().map { rank, row in
            let value = updates[row.id]
            if value == .running { activityAt[row.id] = now }
            if value == .needsReview && (states[row.id] != .needsReview || revisions[row.id] == nil) { revisions[row.id] = UUID().uuidString }
            if let value {
                if states[row.id] != value {
                    if value == .running || (value == .needsReview && states[row.id] == .unknown) { activityAt[row.id] = now }
                    changedAt[row.id] = now
                }
                states[row.id] = value
            }
            var session = AgentSession(id: "desktop:\(row.id)", agentType: .claudeCode,
                state: value == .running ? .working : value == .needsReview ? .completed : value == .unknown ? .idle : .unknown,
                hasUnreadCompletion: false, completionDetectedAt: nil, processId: Int(process.processIdentifier),
                projectPath: nil, worktreePath: nil, sessionTitle: row.title, currentTask: nil,
                startedAt: changedAt[row.id] ?? now, lastActivityAt: changedAt[row.id] ?? now, isActive: value == .running || value == .needsReview,
                wakeupAt: nil, hasBackgroundTasks: false, parentSessionId: nil, rateLimitResetAt: nil,
                tokens5h: 0, tokensWeek: 0, primaryLimit: nil, secondaryLimit: nil)
            session.completionRevision = value == .needsReview ? revisions[row.id] : nil
            session.nativeSidebarRank = rank; session.nativeSelected = row.selected; session.nativeActivityAt = activityAt[row.id]
            session.nativeThreadID = row.id; session.statusSource = "desktop"
            session.sourceRead = value == .unknown
            return session
        }
    }
}
