import Foundation

public final class AgentDiscoveryService {
    private let providers: [IAgentProvider]
    private let registry: AgentSessionRegistry
    private var watchers: [FileSystemEventStream] = []
    private var timer: Timer?
    private let refreshGate = NSLock()
    private var isRefreshing = false

    public init(providers: [IAgentProvider], registry: AgentSessionRegistry) {
        self.providers = providers
        self.registry = registry
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
        refreshGate.lock()
        if isRefreshing {
            refreshGate.unlock()
            return
        }
        isRefreshing = true
        refreshGate.unlock()

        defer {
            refreshGate.lock()
            isRefreshing = false
            refreshGate.unlock()
        }

        var allSessions: [AgentSession] = []
        for provider in providers {
            do {
                let sessions = try await provider.discover()
                allSessions.append(contentsOf: sessions)
                print("Discovery: \(provider.agentType) -> \(sessions.count) sessions [\(sessions.map(\.id).joined(separator: ", "))]")
            } catch {
                NSLog("\(provider.agentType) discovery failed: \(error)")
                allSessions.append(contentsOf: registry.getByAgentType(provider.agentType))
            }
        }
        registry.replace(allSessions)
    }
}
