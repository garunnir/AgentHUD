import Foundation

public final class AgentDiscoveryService {
    private let providers: [IAgentProvider]
    private let registry: AgentSessionRegistry
    private let activity: LiveActivityOverlay?
    private var watchers: [FileSystemEventStream] = []
    private var timer: Timer?
    private let refreshGate = NSLock()
    private var isRefreshing = false

    public init(providers: [IAgentProvider], registry: AgentSessionRegistry, activity: LiveActivityOverlay? = nil) {
        self.providers = providers
        self.registry = registry
        self.activity = activity
    }

    public func start() {
        for root in providers.flatMap({ $0.watchRoots }).filter({ FileManager.default.fileExists(atPath: $0) }) {
            if let stream = try? FileSystemEventStream(path: root, recursive: true) {
                stream.onChange = { [weak self] in Task { await self?.refresh() } }
                stream.start()
                watchers.append(stream)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        watchers.forEach { $0.stop() }
        watchers.removeAll()
    }

    public func refresh() async {
        guard beginRefresh() else { return }
        defer { endRefresh() }

        var allSessions: [AgentSession] = []
        for provider in providers {
            do {
                let sessions = try await provider.discover()
                allSessions.append(contentsOf: sessions)

            } catch {
                NSLog("\(provider.agentType) discovery failed: \(error)")
                // Keep metadata but do not keep a spinner alive after a failed observation.
                allSessions.append(contentsOf: registry.getByAgentType(provider.agentType).filter { $0.nativeThreadID == nil && $0.geminiConversation == nil && !$0.isAppActivity }.map { value in
                    var stale = value; stale.state = .unknown; stale.isActive = false; return stale
                })
            }
        }
        let combined = ClaudeSessionCoalescer.merge(allSessions)
        registry.replace(activity?.apply(combined) ?? combined)
    }
    private func beginRefresh() -> Bool {
        refreshGate.lock(); defer { refreshGate.unlock() }
        guard !isRefreshing else { return false }
        isRefreshing = true
        return true
    }
    private func endRefresh() {
        refreshGate.lock(); defer { refreshGate.unlock() }
        isRefreshing = false
    }

}
