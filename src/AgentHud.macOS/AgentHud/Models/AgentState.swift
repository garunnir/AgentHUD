import Foundation

public enum AgentState: String, Codable, CaseIterable, Sendable {
    case unknown
    case starting
    case working
    case thinking
    case waitingForInput
    case waitingForApproval
    case completed
    case error
    case stopped
    case idle
    case rateLimited
}
