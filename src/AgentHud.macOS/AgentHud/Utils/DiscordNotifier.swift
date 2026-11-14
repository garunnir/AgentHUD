import Foundation
import Security

/// Sends session state changes to a Discord webhook (port of the Windows DiscordNotifier).
/// The webhook URL is a secret, so a message only carries the agent, project name and state,
/// never conversation content. Events from one scan are batched into a single message because
/// webhooks allow 5 requests per 2 seconds.
public final class DiscordNotifier {
    public var enabled = false
    public var webhookURL: String?
    public var notifyAsk = true
    public var notifyComplete = true

    /// Returns the HTTP status code; thrown errors (offline, timeout) count as a failed send.
    typealias Transport = (URLRequest) async throws -> Int
    private let transport: Transport
    private let localiz: Localiz

    init(localiz: Localiz = .current, transport: Transport? = nil) {
        self.localiz = localiz
        self.transport = transport ?? { request in
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
    }

    private static let webhookPattern = try! NSRegularExpression(
        pattern: #"^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+/?$"#)
    static func isValidWebhookURL(_ url: String?) -> Bool {
        guard let url else { return false }
        return webhookPattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    /// nil when the state is not one that is switched on.
    func line(for session: AgentSession, state: AgentState) -> String? {
        let key: String
        switch state {
        case .completed where notifyComplete: key = "Discord.Completed"
        case .waitingForInput where notifyAsk: key = "Discord.WaitingInput"
        case .waitingForApproval where notifyAsk: key = "Discord.WaitingApproval"
        default: return nil
        }
        return HudTheme.formatPattern(localiz.string(key), [Self.escape(session.agentType.displayName), Self.escape(session.projectName)])
    }

    func limitResetLine(for session: AgentSession) -> String {
        HudTheme.formatPattern(localiz.string("Discord.LimitReset"), [Self.escape(session.agentType.displayName), Self.escape(session.projectName)])
    }

    @discardableResult
    func notify(_ events: [(AgentSession, AgentState)]) async -> Bool {
        guard enabled, Self.isValidWebhookURL(webhookURL) else { return false }
        let lines = events.compactMap { line(for: $0.0, state: $0.1) }
        return lines.isEmpty ? false : await send(lines.joined(separator: "\n"))
    }

    @discardableResult
    func notifyLimitReset(_ session: AgentSession) async -> Bool {
        guard enabled, Self.isValidWebhookURL(webhookURL) else { return false }
        return await send(limitResetLine(for: session))
    }

    /// Failures (network, 429, bad URL) only return false so notifications never disturb the app.
    func send(_ content: String) async -> Bool {
        guard Self.isValidWebhookURL(webhookURL), let url = URL(string: webhookURL!) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // An empty `parse` list keeps @everyone, @here and role mentions in the text from pinging anyone.
        let body: [String: Any] = ["content": String(content.prefix(1900)), "allowed_mentions": ["parse": [String]()]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        request.httpBody = data
        guard let status = try? await transport(request) else { return false }
        return (200..<300).contains(status)
    }

    /// Escapes markdown characters so a folder name such as `my_proj` is shown literally.
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\*_~`>|#[]()@".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// The webhook URL works like a password, so it lives in the Keychain (Windows: DPAPI file).
enum DiscordWebhookStore {
    private static let service = "com.garunnir.agenthud.discord-webhook"
    private static let account = "webhook-url"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty or nil URL deletes the stored one. Returns false if the Keychain write failed.
    @discardableResult
    static func save(_ url: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let url, !url.isEmpty else { return true }
        var query = base
        query[kSecValueData as String] = Data(url.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
