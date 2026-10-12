import Foundation

public protocol IAgentProvider {
    var agentType: AgentType { get }
    var watchRoots: [String] { get }
    func discover() async throws -> [AgentSession]
}
