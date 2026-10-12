import Foundation

public enum AgentType: String, Codable, CaseIterable, Sendable {
    case claudeCode = "ClaudeCode"
    case codex = "Codex"
    case openCode = "OpenCode"
    case openCodeGo = "OpenCodeGo"

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .openCodeGo: return "OpenCode Go"
        }
    }
}
