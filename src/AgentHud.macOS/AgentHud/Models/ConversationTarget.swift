import Foundation

public enum ConversationTarget: String, CaseIterable, Identifiable {
    case visualStudioCode = "vscode"
    case claudeDesktop = "claudeDesktop"
    case chatGPTDesktop = "chatGPTDesktop"
    case openCodeDesktop = "openCodeDesktop"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .visualStudioCode: return "VS Code"
        case .claudeDesktop: return "Claude Desktop"
        case .chatGPTDesktop: return "ChatGPT Desktop"
        case .openCodeDesktop: return "OpenCode Desktop"
        }
    }
}
