import Foundation
import Security

/// The OpenCode Console's Go status is a browser-session endpoint, not a provider
/// API-key endpoint. The login sheet stores only the Console cookies in Keychain.
public struct OpenCodeGoUsage {
    public let fiveHour: LimitWindow
    public let week: LimitWindow
    public let month: LimitWindow
    public let fetchedAt: Date
}

public enum OpenCodeGoUsageError: Error, Equatable {
    case notLoggedIn
    case missingWorkspace
    case unauthorized
    case http(Int)
    case badResponse
}

public final class OpenCodeGoUsageApi {
    public static let shared = OpenCodeGoUsageApi()
    public static let refreshInterval: TimeInterval = 5 * 60

    private let endpoint = URL(string: "https://opencode.ai/console/api/go/status")!
    private let keychainService = "com.garunnir.agenthud.opencode-console"
    private init() {}

    private struct Status: Decodable {
        struct Meter: Decodable {
            let startsAt: Date?
            let resetsAt: Date
            let limitMicroCents: String
            let usedMicroCents: String
        }
        struct Access: Decodable {
            let startsAt: Date?
            let endsAt: Date?
            let meters: Meters
        }
        struct Meters: Decodable {
            let fiveHour: Meter
            let week: Meter
            let month: Meter
        }
        let product: String
        let access: Access
    }

    private struct StoredCookie: Codable {
        let name: String
        let value: String
    }

    public var hasCookies: Bool { loadCookies() != nil }

    public func saveCookies(_ cookies: [HTTPCookie]) throws {
        let stored = cookies
            .filter { $0.domain.hasSuffix("opencode.ai") }
            .map { StoredCookie(name: $0.name, value: $0.value) }
        guard !stored.isEmpty else { throw OpenCodeGoUsageError.notLoggedIn }
        let data = try JSONEncoder().encode(stored)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "console-cookies",
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw OpenCodeGoUsageError.notLoggedIn
        }
    }

    public func clearCookies() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "console-cookies"
        ]
        SecItemDelete(query as CFDictionary)
    }

    public func fetch(workspaceId: String) async throws -> OpenCodeGoUsage {
        let workspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceId.isEmpty else { throw OpenCodeGoUsageError.missingWorkspace }
        guard let cookies = loadCookies() else { throw OpenCodeGoUsageError.notLoggedIn }

        var request = URLRequest(url: endpoint)
        request.setValue(workspaceId, forHTTPHeaderField: "x-org-id")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw OpenCodeGoUsageError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw OpenCodeGoUsageError.http(http.statusCode) }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(Status.self, from: data), status.product.hasPrefix("go") else {
            throw OpenCodeGoUsageError.badResponse
        }
        let access = status.access
        return OpenCodeGoUsage(
            fiveHour: makeWindow(access.meters.fiveHour),
            week: makeWindow(access.meters.week),
            month: makeWindow(access.meters.month),
            fetchedAt: Date()
        )
    }

    private func makeWindow(_ meter: Status.Meter) -> LimitWindow {
        let limit = Double(meter.limitMicroCents) ?? 0
        let used = Double(meter.usedMicroCents) ?? 0
        let percent = limit > 0 ? min(max(used / limit * 100, 0), 100) : 0
        let minutes: Int?
        if let starts = meter.startsAt {
            minutes = max(1, Int(meter.resetsAt.timeIntervalSince(starts) / 60))
        } else {
            minutes = nil
        }
        return LimitWindow(usedPercent: percent, resetsAt: meter.resetsAt, windowMinutes: minutes)
    }

    private func loadCookies() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "console-cookies",
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let cookies = try? JSONDecoder().decode([StoredCookie].self, from: data),
              !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
