import Foundation
import WebKit

/// claude.ai usage API (unofficial), the macOS port of `src/AgentHud/ClaudeUsageApi.cs`.
///
/// The statusLine only runs inside the interactive CLI, so sessions driven by the desktop
/// app / VS Code extension leave `claude-limits.json` stale. This opt-in source fills the
/// `api` slot of `ClaudeLimitPolicy.pick`.
///
/// Instead of a pasted sessionKey + org ID, the user signs in once in an in-app web view.
/// The session lives only in a dedicated WebKit data store (not shared with OpenCode or
/// Safari), and requests go through an off-screen WKWebView in that store because
/// Cloudflare blocks plain URLSession; a challenge the hidden view cannot pass is cleared by
/// signing in again, which stores the clearance cookie in the same store.
///
/// Verified 2026-10-21 with a real claude.ai sign-in on macOS: the hidden WKWebView passes
/// Cloudflare, `GET /api/organizations` yields a usable `uuid`, and
/// `GET /api/organizations/{uuid}/usage` returns `five_hour` / `seven_day`
/// `{utilization, resets_at}` (same shape the Windows port parses). The plan capability
/// names used by `pickOrganization` are a best guess; it falls back to any chat org.
@MainActor
public final class ClaudeUsageApi: NSObject, ObservableObject {
    public static let shared = ClaudeUsageApi()
    public static let refreshInterval: TimeInterval = 5 * 60
    /// Backoff after a transient failure; auth / Cloudflare failures wait a full interval
    /// so a dead session does not hit the unofficial endpoint every minute.
    nonisolated private static let failureRetry: TimeInterval = 60
    private static let navigationTimeout: UInt64 = 25_000_000_000
    private static let storeIdentifier = UUID(uuidString: "6F1C2A7E-3B5D-4E8A-9C21-AE0C1D7B5F42")!
    /// Cloudflare ties its clearance cookie to the user agent; the login sheet and the
    /// hidden fetcher must present the same one.
    static let applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
    static let loginURL = URL(string: "https://claude.ai/login")!

    let dataStore = WKWebsiteDataStore(forIdentifier: ClaudeUsageApi.storeIdentifier)

    /// Opt-in toggle, owned by the view model's persisted setting.
    public var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            resetResult()
            if enabled { refreshLoginState(thenRefresh: true) } else { setStatus("Api.Disabled") }
        }
    }
    /// True when the store holds a claude.ai `sessionKey` cookie.
    @Published public private(set) var hasSession = false
    @Published public private(set) var snapshot: ClaudeLimitSnapshot = .none
    @Published private var status: (key: String, args: [Any]) = ("Api.Disabled", [])
    public var statusText: String { HudTheme.formatPattern(Localiz.current.string(status.key), status.args) }

    private var orgId: String?
    private var lastAttempt: Date?
    private var retryAt: Date?
    private var task: Task<Void, Never>?
    private var webView: WKWebView?
    private var pending: (status: Int, done: CheckedContinuation<Int, Never>)?
    private var navigationID = 0

    private override init() { super.init() }

    public func refreshIfNeeded(now: Date = Date()) {
        guard enabled, hasSession, task == nil else { return }
        if let retryAt, now < retryAt { return }
        if let lastAttempt, retryAt == nil, now.timeIntervalSince(lastAttempt) < Self.refreshInterval { return }
        refresh()
    }

    public func refresh() {
        guard enabled, task == nil else { return }
        lastAttempt = Date()
        task = Task { [weak self] in
            await self?.fetch()
            self?.task = nil
        }
    }

    /// Called by the login sheet's Done button. Returns false when no session cookie is there.
    public func loginFinished(_ completion: @escaping (Bool) -> Void) {
        // A new login may be a different account: forget the old org and value first.
        resetResult()
        refreshLoginState(thenRefresh: true) { completion($0) }
    }

    public func logout() {
        task?.cancel()
        task = nil
        finishNavigation(-1)
        webView = nil
        resetResult()
        hasSession = false
        setStatus(enabled ? "Api.LoginRequired" : "Api.Disabled")
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    private func resetResult() {
        orgId = nil
        snapshot = .none
        lastAttempt = nil
        retryAt = nil
    }

    private func refreshLoginState(thenRefresh: Bool, completion: ((Bool) -> Void)? = nil) {
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self else { return }
                let found = cookies.contains { $0.name == "sessionKey" && $0.domain.hasSuffix("claude.ai") }
                self.hasSession = found
                if !found, self.enabled { self.setStatus("Api.LoginRequired") }
                if found, thenRefresh { self.refresh() }
                completion?(found)
            }
        }
    }

    private func fetch() async {
        if orgId == nil {
            let (code, body) = await get("https://claude.ai/api/organizations")
            guard check(code, body) else { return }
            guard let org = Self.pickOrganization(Data(body.utf8)) else { fail("Api.NoOrganization"); return }
            orgId = org
        }
        guard let org = orgId else { return }
        let (code, body) = await get("https://claude.ai/api/organizations/\(org)/usage")
        guard check(code, body) else { return }
        let parsed = ClaudeLimitSnapshot.parseUsageApi(Data(body.utf8), updatedAt: Date())
        guard parsed.hasData else { snapshot = .none; fail("Api.NoLimits"); return }
        snapshot = parsed
        retryAt = nil
        setStatus("Api.Connected", Date())
    }

    /// true = 200 with a real body; otherwise records the failure status and returns false.
    private func check(_ code: Int, _ body: String) -> Bool {
        if Self.looksLikeChallenge(body) { fail("Api.Blocked", retry: Self.refreshInterval); return false }
        if code == 200 { return true }
        if code == 401 || code == 403 {
            // Expired or revoked session: drop the value so the HUD falls back to the statusLine.
            snapshot = .none
            orgId = nil
            refreshLoginState(thenRefresh: false)
            fail("Api.AuthFailed", code, "", retry: Self.refreshInterval)
        } else if code == 404 {
            orgId = nil
            fail("Api.RequestFailed", code, "")
        } else if code < 0 {
            fail("Api.ConnectFailed")
        } else {
            fail("Api.RequestFailed", code, "")
        }
        return false
    }

    private func fail(_ key: String, _ args: Any..., retry: TimeInterval = failureRetry) {
        retryAt = Date().addingTimeInterval(retry)
        status = (key, args)
    }

    private func setStatus(_ key: String, _ args: Any...) { status = (key, args) }

    // MARK: - Off-screen WKWebView fetch

    /// Navigates the hidden view to `url` and returns (HTTP status, page text). Waits briefly
    /// for a Cloudflare JS challenge to resolve itself, like the Windows WebViewFetcher.
    private func get(_ url: String) async -> (Int, String) {
        let view = webView ?? makeWebView()
        navigationID += 1
        let id = navigationID
        let code: Int = await withCheckedContinuation { done in
            pending = (-1, done)
            view.load(URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
            // WebKit may never report back (e.g. a challenge redirect in an unparented view);
            // without this the fetch task would stay pending and block every later refresh.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.navigationTimeout)
                if self?.navigationID == id { self?.finishNavigation(-1) }
            }
        }
        var body = await readBody(view)
        var status = code
        for _ in 0..<16 where Self.looksLikeChallenge(body) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            body = await readBody(view)
            if !Self.looksLikeChallenge(body) { status = 200 }
        }
        return (status, body)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = Self.applicationNameForUserAgent
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        return view
    }

    private func readBody(_ view: WKWebView) async -> String {
        (try? await view.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String) ?? ""
    }

    private func finishNavigation(_ code: Int?) {
        guard let pending else { return }
        self.pending = nil
        pending.done.resume(returning: code ?? pending.status)
    }

    nonisolated static func looksLikeChallenge(_ body: String) -> Bool {
        body.range(of: "just a moment|challenge-platform|cf-chl|cdn-cgi/challenge|_cf_chl|checking your browser",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Prefers the organization that carries the Pro/Max chat plan (that is the one the
    /// CLI login uses), then any chat-capable one, then the first.
    nonisolated static func pickOrganization(_ data: Data) -> String? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let orgs = list.compactMap { org -> (id: String, caps: [String])? in
            guard let id = org["uuid"] as? String else { return nil }
            return (id, org["capabilities"] as? [String] ?? [])
        }
        return (orgs.first { $0.caps.contains { $0 == "claude_max" || $0 == "claude_pro" } }
            ?? orgs.first { $0.caps.contains("chat") }
            ?? orgs.first)?.id
    }
}

extension ClaudeUsageApi: WKNavigationDelegate {
    nonisolated public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                                    decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        MainActor.assumeIsolated {
            if navigationResponse.isForMainFrame, let code = (navigationResponse.response as? HTTPURLResponse)?.statusCode {
                pending?.status = code
            }
            decisionHandler(.allow)
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishNavigation(nil) }
    }

    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishNavigation(-1) }
    }

    nonisolated public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishNavigation(-1) }
    }
}
