import Foundation

public enum AgentType: String, Codable, CaseIterable, Sendable {
    case claudeCode = "ClaudeCode"
    case codex = "Codex"

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        }
    }
}
