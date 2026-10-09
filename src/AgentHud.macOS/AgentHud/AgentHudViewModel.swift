import SwiftUI
import Combine

@MainActor
public final class AgentHudViewModel: ObservableObject {
    @Published public var sessions: [AgentSession] = []
    @Published public var isMinimized = false
    @Published public var hiddenSessionIds: Set<String> = []
    @Published public var memos: [String: String] = [:]

    private let registry: AgentSessionRegistry
    private let discovery: AgentDiscoveryService
    private var updateTask: Task<Void, Never>?

    public init() {
        let registry = AgentSessionRegistry()
        self.registry = registry
        let home = NSHomeDirectory()
        let providers: [IAgentProvider] = [
            ClaudeCodeProvider(home: home),
            CodexProvider(home: home)
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
}
