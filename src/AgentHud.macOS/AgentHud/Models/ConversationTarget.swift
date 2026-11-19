import Foundation

public enum ConversationTarget: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case visualStudioCode = "vscode"
    case claudeDesktop = "claudeDesktop"
    case chatGPTDesktop = "chatGPTDesktop"
    case openCodeDesktop = "openCodeDesktop"
    case ampDesktop = "ampDesktop"
    case geminiDesktop = "geminiDesktop"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return Localiz.current.string("Settings.DesktopFirst")
        case .visualStudioCode: return "VS Code"
        case .claudeDesktop: return "Claude Desktop"
        case .chatGPTDesktop: return "Codex Desktop (GPT)"
        case .openCodeDesktop: return "OpenCode Desktop"
        case .ampDesktop: return "Amp Desktop"
        case .geminiDesktop: return "Gemini Desktop"
        }
    }
}
