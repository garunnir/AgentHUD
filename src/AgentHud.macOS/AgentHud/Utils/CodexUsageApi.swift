import Foundation

/// Live Codex usage straight from the server.
///
/// The ChatGPT app's bundled Codex consumes quota without writing to ~/.codex/sessions,
/// so local session logs go stale. This hits the same endpoint the ChatGPT app uses
/// (found via its bundled CLI), which always reports the real windows.
///
/// The bearer token is read from ~/.codex/auth.json (owned by Codex itself) at call
/// time and never stored anywhere else.
public struct CodexUsage {
    public let primary: LimitWindow?
    public let secondary: LimitWindow?
    public let planType: String?
    public let limitReached: Bool

    public init(primary: LimitWindow?, secondary: LimitWindow?,
                planType: String?, limitReached: Bool) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.limitReached = limitReached
    }
}

public enum CodexUsageError: Error, Equatable {
    case noAuthFile
    case unauthorized
    case http(Int)
    case badResponse
}

public final class CodexUsageApi {
    public static let shared = CodexUsageApi()

    private init() {}

    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// The endpoint is cheap but not free; mirror the Windows 5-minute cadence.
    public static let refreshInterval: TimeInterval = 5 * 60

    private struct Response: Decodable {
        struct RateLimit: Decodable {
            struct Window: Decodable {
                let used_percent: Double
                let limit_window_seconds: Int?
                let reset_after_seconds: Int?
                let reset_at: Double?
            }
            let primary_window: Window?
            let secondary_window: Window?
            let limit_reached: Bool?
        }
        let rate_limit: RateLimit?
        let plan_type: String?
    }

    private func makeRequest() throws -> URLRequest {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw CodexUsageError.noAuthFile
        }
        let accountId = tokens["account_id"] as? String

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        return request
    }

    public func fetchUsage() async throws -> CodexUsage {
        let (data, response) = try await URLSession.shared.data(for: makeRequest())
        return try Self.parse(data: data, response: response)
    }

    /// Blocking variant for the `--usage-selftest` debug flag, which must run before
    /// the app creates any window. Not used by the UI itself.
    public func fetchUsageSync() throws -> CodexUsage {
        let semaphore = DispatchSemaphore(value: 0)
        final class Outcome {
            var data: Data?
            var response: URLResponse?
        }
        let outcome = Outcome()
        URLSession.shared.dataTask(with: try makeRequest()) { data, response, _ in
            outcome.data = data
            outcome.response = response
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        guard let data = outcome.data, let response = outcome.response else {
            throw CodexUsageError.badResponse
        }
        return try Self.parse(data: data, response: response)
    }

    private static func parse(data: Data, response: URLResponse) throws -> CodexUsage {
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw CodexUsageError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw CodexUsageError.http(http.statusCode) }
        }
        guard let json = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CodexUsageError.badResponse
        }

        func window(_ w: Response.RateLimit.Window?) -> LimitWindow? {
            guard let w else { return nil }
            let minutes = w.limit_window_seconds.map { $0 / 60 }
            // reset_at is authoritative; reset_after_seconds is server-relative to "now".
            let resetsAt = w.reset_at.map { Date(timeIntervalSince1970: $0) }
                ?? Date().addingTimeInterval(TimeInterval(w.reset_after_seconds ?? 0))
            return LimitWindow(usedPercent: w.used_percent,
                               resetsAt: resetsAt,
                               windowMinutes: minutes)
        }
        return CodexUsage(
            primary: window(json.rate_limit?.primary_window),
            secondary: window(json.rate_limit?.secondary_window),
            planType: json.plan_type,
            limitReached: json.rate_limit?.limit_reached ?? false
        )
    }
}
