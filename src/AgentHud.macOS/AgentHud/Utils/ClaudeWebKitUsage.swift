import AppKit
import WebKit
import OSLog

@MainActor
final class ClaudeWebKitUsage: NSObject, UsageConnectionModel, NSWindowDelegate {
    @Published private(set) var snapshot: ClaudeLimitSnapshot?
    @Published private(set) var statusKey = "Settings.ClaudeWebHint"
    @Published private(set) var connecting = false
    @Published private(set) var fetching = false
    let connectKey = "Settings.ClaudeWebConnect"

    private static let log = Logger(subsystem: "com.garunnir.agenthud", category: "ClaudeUsage")
    private let linkedKey = "hud.claudeWebKitUsageLinked"
    private let store = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "15AC311D-89EA-4AC2-9D3E-7056D8C73914")!)
    private var login: NSWindow?
    private var loop: Task<Void, Never>?
    private var nextAttempt = Date.distantPast

    private func makePage() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.preferences.inactiveSchedulingPolicy = .none
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 720), configuration: config)
        view.load(URLRequest(url: URL(string: ClaudeUsagePage.settingsURL)!, cachePolicy: .reloadIgnoringLocalCacheData))
        return view
    }

    func connect() {
        if let login { login.close(); return }
        guard !fetching else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AgentHUD · Claude"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makePage()
        window.center()
        login = window
        connecting = true
        statusKey = "Settings.ClaudeWebHint"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === login else { return }
        window.contentView = nil
        login = nil
        connecting = false
        snapshot = nil
        UserDefaults.standard.set(true, forKey: linkedKey)
        nextAttempt = .distantPast
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    private func refresh() async {
        guard !connecting, !fetching, UserDefaults.standard.bool(forKey: linkedKey), Date() >= nextAttempt else { return }
        fetching = true
        let page = makePage()
        defer { page.stopLoading(); fetching = false }
        for _ in 0..<24 {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard page.url?.host == "claude.ai" else { continue }
            if !page.isLoading, page.url?.path == "/login" {
                statusKey = "Settings.ClaudeWebSignIn"
                UserDefaults.standard.set(false, forKey: linkedKey)
                snapshot = nil
                return
            }
            guard let data = try? await page.callAsyncJavaScript(Self.projectUsage, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any],
                  !Task.isCancelled else { continue }
            let now = Date()
            if let result = Self.sample(data, now: now) {
                snapshot = result
                Self.log.info("Background weekly usage refreshed")
                statusKey = "Settings.ClaudeWebReady"
                nextAttempt = now.addingTimeInterval(300)
                return
            }
        }
        statusKey = "Settings.ClaudeWebFailed"
        nextAttempt = Date().addingTimeInterval(60)
    }

    static func sample(_ data: [String: Any], now: Date) -> ClaudeLimitSnapshot? {
        guard let rows = data["meters"] as? [[String: Any]] else { return nil }
        let meters = rows.compactMap { row -> ClaudeUsagePage.Meter? in
            guard let name = row["title"] as? String, let used = row["used"] as? Double,
                  let labels = row["labels"] as? [String] else { return nil }
            return .init(title: name, used: used, resetsAt: ClaudeUsagePage.weeklyReset(in: labels, now: now))
        }
        let result = ClaudeUsagePage.snapshot(meters: meters, heading: data["heading"] as? Bool == true,
                                              fresh: data["fresh"] as? Bool == true, now: now)
        guard let week = result?.sevenDay, week.resetsAt != nil || week.usedPercent == 0 else { return nil }
        return result
    }

    private static let projectUsage = #"""
    if (location.origin !== 'https://claude.ai') return {};
    const normalize = s => (s || '').replace(/\s+/g, ' ').trim();
    const weeklyName = /^(이번 주|this week|all models|모든 모델)$/i;
    const headings = [...document.querySelectorAll('h1,h2,h3,[role=heading]')];
    const heading = headings.some(e => /^(usage|사용량)$/i.test(normalize(e.textContent)));
    if (!heading) return {};
    const lines = e => (e.innerText || '').split('\n').map(normalize).filter(Boolean);
    const pageText = lines(document.body).join(' ');
    const fresh = /마지막 업데이트\s*[:：]?\s*(방금 전|1분 전)|last updated\s*[:：]?\s*(just now|1 minute ago)/i.test(pageText);
    const meters = [];
    const elements = [...document.querySelectorAll('meter,progress,[role=meter],[role=progressbar]')];
    for (const node of elements) {
        const refs = (node.getAttribute('aria-labelledby') || '').trim().split(/\s+/)
            .map(id => document.getElementById(id)).filter(Boolean);
        const accessibleName = normalize(node.getAttribute('aria-label') || refs.map(e => e.innerText || e.textContent).join(' '));
        const attr = node.getAttribute('aria-valuenow') ?? node.getAttribute('value');
        const max = Number(node.getAttribute('aria-valuemax') ?? node.getAttribute('max') ?? 100);
        if (attr === null || !Number.isFinite(Number(attr)) || !(max > 0)) continue;
        for (let box = node.parentElement; box && box !== document.body; box = box.parentElement) {
            if (elements.filter(e => box.contains(e)).length > 1) break;
            const text = normalize(box.innerText);
            const found = text.match(/\(?[일월화수목금토](?:요일)?\)?\s*(?:오전|오후)?\s*\d{1,2}:\d{2}\s*에\s*초기화|resets?\s+(?:on\s+)?(?:sun|mon|tue|wed|thu|fri|sat)[a-z]*\.?[,]?\s+(?:at\s+)?\d{1,2}(?::\d{2})?\s*(?:am|pm)?/i);
            const isWeek = weeklyName.test(accessibleName) || /이번\s*주|this week|all models|모든 모델/i.test(text);
            if (isWeek && (found || (Number(attr) === 0 && weeklyName.test(accessibleName)))) {
                meters.push({title: 'this week', used: Number(attr) * 100 / max, labels: found ? [found[0]] : []});
                break;
            }
            if (/^(current session|현재 세션)$/i.test(accessibleName)) {
                meters.push({title: accessibleName, used: Number(attr) * 100 / max, labels: []});
                break;
            }
        }
    }
    if (!meters.some(m => weeklyName.test(m.title))) {
        const week = [...document.querySelectorAll('button,[role=button]')].find(b => weeklyName.test(normalize(b.innerText)));
        const freshUsed = elements.filter(e => /^\s*\d+(?:\.\d+)?\s*%\s*(사용됨|used)\s*$/i.test(e.getAttribute('aria-valuetext') || ''));
        if (week && freshUsed.length === 1) {
            const dates = lines(document.body).filter(t => /^(?:\([일월화수목금토]요일\)|resets?\s+(?:on\s+)?(?:sun|mon|tue|wed|thu|fri|sat))/i.test(t));
            if (dates.length === 1) meters.push({title: 'this week', used: Number.parseFloat(freshUsed[0].getAttribute('aria-valuetext')), labels: dates});
        }
    }
    return {heading, fresh, meters};
    """#
}
