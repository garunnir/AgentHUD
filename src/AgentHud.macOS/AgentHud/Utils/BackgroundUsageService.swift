import AppKit

@MainActor
protocol UsageConnectionModel: ObservableObject {
    var statusKey: String { get }
    var connectKey: String { get }
    var connecting: Bool { get }
    var fetching: Bool { get }
    func connect()
}

protocol UsageSettingsPage {
    associatedtype Snapshot: Sendable
    static var serviceName: String { get }
    static var settingsURL: String { get }
    static func read(chrome: URL, profile: URL) -> Snapshot?
}

/// Polls a single provider's settings in a dedicated, hidden Chrome instance.
@MainActor
final class BackgroundUsageService<Page: UsageSettingsPage>: UsageConnectionModel {
    @Published private(set) var snapshot: Page.Snapshot?
    @Published private(set) var statusKey = "Settings.\(Page.serviceName)WebHint"
    var connectKey: String { "Settings.\(Page.serviceName)WebConnect" }
    @Published private(set) var connecting = false
    @Published private(set) var fetching = false

    private let profile = AgentHudViewModel.dataDirectory.appendingPathComponent("\(Page.serviceName)UsageProfile")
    private var setup: NSRunningApplication?
    private var loop: Task<Void, Never>?
    private var nextAttempt = Date.distantPast

    private func owns(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier == "com.google.Chrome", !app.isTerminated,
              let lock = try? FileManager.default.destinationOfSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path)
        else { return false }
        return lock.caseInsensitiveCompare(ProcessInfo.processInfo.hostName + "-\(app.processIdentifier)") == .orderedSame
    }

    private func openLoginPage() async -> NSRunningApplication? {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            statusKey = "Settings.\(Page.serviceName)WebChrome"
            return nil
        }
        guard profile.resolvingSymlinksInPath().path == profile.path else { return nil }
        // Do not open a window in, or terminate, another live instance using the profile.
        if let lock = try? FileManager.default.destinationOfSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path) {
            guard let dash = lock.lastIndex(of: "-"), String(lock[..<dash]).caseInsensitiveCompare(ProcessInfo.processInfo.hostName) == .orderedSame,
                  let pid = Int32(lock[lock.index(after: dash)...]), pid > 1,
                  kill(pid, 0) == -1, errno == ESRCH else { return nil }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true
        config.addsToRecentItems = false
        config.arguments = ["--user-data-dir=" + profile.path, "--force-renderer-accessibility", "--no-first-run",
                            "--no-default-browser-check", "--disable-sync", "--disable-background-mode",
                            "--app=" + Page.settingsURL]
        return try? await NSWorkspace.shared.openApplication(at: chrome, configuration: config)
    }

    func connect() {
        if connecting, let setup {
            if owns(setup) { setup.terminate() }
            // The polling loop resumes once Chrome releases the profile.
            return
        }
        guard !connecting, !fetching else { return }
        do { try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { statusKey = "Settings.\(Page.serviceName)WebFailed"; return }
        connecting = true
        snapshot = nil
        statusKey = "Settings.\(Page.serviceName)WebHint"
        Task {
            setup = await openLoginPage()
            if setup == nil { connecting = false }
        }
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
        if connecting, setup?.isTerminated == true {
            setup = nil
            connecting = false
            nextAttempt = .distantPast
        }
        guard !connecting, !fetching, Date() >= nextAttempt, FileManager.default.fileExists(atPath: profile.path) else { return }
        nextAttempt = Date().addingTimeInterval(300)
        fetching = true
        defer { fetching = false }
        statusKey = "Settings.\(Page.serviceName)WebFailed"
        guard profile.resolvingSymlinksInPath().path == profile.path,
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let executable = Bundle(url: chrome)?.executableURL else { return }
        let directory = profile
        let sample = await Task.detached(priority: .utility) { Page.read(chrome: executable, profile: directory) }.value
        if !Task.isCancelled, let sample {
            snapshot = sample
            statusKey = "Settings.\(Page.serviceName)WebReady"
        }
    }
}
