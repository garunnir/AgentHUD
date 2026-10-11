import Foundation

public enum AgentType: String, Codable, CaseIterable, Sendable {
    case claudeCode = "ClaudeCode"
    case codex = "Codex"
    case openCodeGo = "OpenCodeGo"

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .openCodeGo: return "OpenCode Go"
        }
    }
}
