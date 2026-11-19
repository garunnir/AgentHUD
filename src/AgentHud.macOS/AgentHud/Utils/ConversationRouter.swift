import AppKit
import ApplicationServices

public enum ConversationOpenResult: Equatable {
    case desktopRouteAccepted, nativeSelectionAccepted, extensionRequested, projectOnly, failed
    public var acknowledgesCompletion: Bool { self == .desktopRouteAccepted || self == .nativeSelectionAccepted }
}

public enum ConversationRoute: Equatable {
    case codex(URL)
    case gemini(GeminiConversationReference)
    case nativeClaude(String, Int)
    case claudeLocal(String)
    case claudeDesktop(String)
    case nativeSidebar(AgentApp, String, Int)
    case openCode(String)
    case vscode(URL?, String?)
}

public enum ConversationRoutePolicy {
    public static func routes(for session: AgentSession, preference: ConversationTarget,
                              runningBundles: Set<String>, pathExists: (String) -> Bool) -> [ConversationRoute] {
        guard !session.isAppActivity else { return [] }
        var routes: [ConversationRoute] = []
        let automatic = preference == .automatic
        let desktop = preference != .visualStudioCode
        if desktop {
            switch session.agentType {
            case .codex:
                if (automatic && runningBundles.contains("com.openai.codex")) || preference == .chatGPTDesktop {
                    if let id = uuid(session.id, prefix: "codex:") {
                        routes.append(.codex(URL(string: "codex://threads/\(id)")!))
                    }
                }
            case .claudeCode:
                if (automatic && runningBundles.contains("com.anthropic.claudefordesktop")) || preference == .claudeDesktop {
                    if let id = session.claudeDesktopID, ClaudeDesktopLink.validDesktopID(id) { routes.append(.claudeDesktop(id)) }
                else if let id = uuid(session.id, prefix: "claude:") { routes.append(.claudeLocal(id)) }
                    else if let id = session.nativeThreadID, let pid = session.nativeProcessId ?? session.processId {
                        routes.append(.nativeClaude(id, pid))
                    }
                }
            case .gemini where session.geminiConversation != nil:
                if (automatic && runningBundles.contains("com.google.GeminiMacOS")) || preference == .geminiDesktop,
                   let reference = session.geminiConversation, reference.isValid { routes.append(.gemini(reference)) }
            case .amp, .gemini:

                let app: AgentApp = session.agentType == .amp ? .amp : .gemini
                let explicit = session.agentType == .amp ? preference == .ampDesktop : preference == .geminiDesktop
                if (automatic && app.bundleIDs.contains(where: runningBundles.contains)) || explicit,
                   let id = session.nativeThreadID, let pid = session.processId {
                    routes.append(.nativeSidebar(app, id, pid))
                }
            case .openCode, .openCodeGo:
                if (automatic && runningBundles.contains("ai.opencode.desktop")) || preference == .openCodeDesktop,
                   session.id.hasPrefix("opencode:") {
                    let id = String(session.id.dropFirst("opencode:".count))
                    if ActivityFileStore.validSessionID(id) { routes.append(.openCode(id)) }
                }
            }
        }
        // A desktop UUID route does not require the old project directory to still exist.
        let path = [session.worktreePath, session.projectPath].compactMap { $0 }.first(where: pathExists)
        var uri: URL?
        if session.agentType == .codex, let id = uuid(session.id, prefix: "codex:") {
            uri = URL(string: "vscode://openai.chatgpt/local/\(id)")
        } else if session.agentType == .claudeCode, let id = uuid(session.id, prefix: "claude:") {
            uri = URL(string: "vscode://anthropic.claude-code/open?session=\(id)")
        }
        if path != nil || uri != nil { routes.append(.vscode(uri, path)) }
        return routes
    }
    private static func uuid(_ id: String, prefix: String) -> String? {
        guard id.hasPrefix(prefix), let uuid = UUID(uuidString: String(id.dropFirst(prefix.count))) else { return nil }
        return uuid.uuidString.lowercased()
    }
}

@MainActor
final class ConversationRouter {
    private let native: NativeSidebarClient
    private var navigationGeneration = 0
    init(native: NativeSidebarClient) { self.native = native }
    func open(_ session: AgentSession, preference: ConversationTarget) async -> ConversationOpenResult {
        navigationGeneration &+= 1
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let routes = ConversationRoutePolicy.routes(for: session, preference: preference, runningBundles: running,
                                                    pathExists: FileManager.default.fileExists(atPath:))
        return await Self.run(routes: routes) { await self.perform($0) }
    }
    static func run(routes: [ConversationRoute], perform: (ConversationRoute) async -> ConversationOpenResult) async -> ConversationOpenResult {
        for route in routes {
            let result = await perform(route)
            if result != .failed { return result }
        }
        return .failed
    }
    private func perform(_ route: ConversationRoute) async -> ConversationOpenResult {
        switch route {
        case let .codex(url):
            return await openURLs([url], bundle: "com.openai.codex") ? .desktopRouteAccepted : .failed
        case let .gemini(reference):
            let store = GeminiHistoryStore(root: GeminiHistoryStore.defaultRoot())
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.GeminiMacOS").first,
                  await native.hasLiveSidebar(app: .gemini, pid: process.processIdentifier),
                  store.contains(reference), let url = reference.url else { return .failed }
            let pid = process.processIdentifier
            let generation = navigationGeneration
            let before = await native.geminiWindowTitle(pid: pid)
            guard await openURLs([url], bundle: "com.google.GeminiMacOS") else { return .failed }
            if let before {
                Task { await learnGeminiTitle(reference, before: before, pid: pid, generation: generation) }
            }
            return .desktopRouteAccepted
        case let .claudeLocal(id):
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else { return .failed }
            let pid = process.processIdentifier
            let link = await Task.detached(priority: .utility) { ClaudeDesktopLink.find(cliID: id) }.value
            guard let link, let url = link.url, let live = NSRunningApplication(processIdentifier: pid),
                  !live.isTerminated, live.bundleIdentifier == "com.anthropic.claudefordesktop",
                  await openURLs([url], bundle: "com.anthropic.claudefordesktop") else { return .failed }
            return await native.confirmClaudeLocalID(link.sessionId, pid: pid) ? .desktopRouteAccepted : .failed
        case let .claudeDesktop(id):
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else { return .failed }
            let pid = process.processIdentifier
            let metadata = await Task.detached(priority: .utility) { ClaudeDesktopLink.readMetadata(id) }.value
            guard let metadata, let url = metadata.url, let live = NSRunningApplication(processIdentifier: pid),
                  !live.isTerminated, live.bundleIdentifier == "com.anthropic.claudefordesktop",
                  await openURLs([url], bundle: "com.anthropic.claudefordesktop") else { return .failed }
            return await native.confirmClaudeLocalID(id, pid: pid) ? .desktopRouteAccepted : .failed
        case let .nativeClaude(id, pid):

            guard let process = NSRunningApplication(processIdentifier: pid_t(pid)),
                  process.bundleIdentifier == "com.anthropic.claudefordesktop", !process.isTerminated,
                  process.activate(options: [.activateIgnoringOtherApps]) else { return .failed }
            return await native.selectKnown(id: id, app: .claude, pid: pid_t(pid)) ? .nativeSelectionAccepted : .failed
        case let .nativeSidebar(app, id, pid):
            guard [.amp, .gemini].contains(app), let process = NSRunningApplication(processIdentifier: pid_t(pid)),
                  app.bundleIDs.contains(process.bundleIdentifier ?? ""), !process.isTerminated,
                  process.activate(options: [.activateIgnoringOtherApps]) else { return .failed }
            return await native.selectKnown(id: id, app: app, pid: pid_t(pid)) ? .nativeSelectionAccepted : .failed
        case let .openCode(id):
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.opencode.desktop").first,
                  AXIsProcessTrusted() else { return .failed }
            let result = await native.scan(app: .openCode, pid: process.processIdentifier)
            guard let row = result.threads.first(where: { $0.activitySessionID == id }) else { return .failed }
            guard process.activate(options: [.activateIgnoringOtherApps]) else { return .failed }
            do { try await native.select(row, pid: process.processIdentifier); return .nativeSelectionAccepted }
            catch { return .failed }
        case let .vscode(uri, path):
            if let path, !(await openURLs([URL(fileURLWithPath: path)], bundle: "com.microsoft.VSCode")) { return .failed }
            if let uri, await openURLs([uri], bundle: "com.microsoft.VSCode") { return .extensionRequested }
            return path == nil ? .failed : .projectOnly
        }
    }
    private func learnGeminiTitle(_ reference: GeminiConversationReference, before: String, pid: pid_t, generation: Int) async {
        let started = ProcessInfo.processInfo.systemUptime
        var candidate: String?
        var matches = 0
        for _ in 0..<35 {
            try? await Task.sleep(for: .milliseconds(180))
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            // A second user navigation can change the same window while the deep link opens.
            let inputs: [CGEventType] = [.leftMouseDown, .rightMouseDown, .keyDown]
            guard generation == navigationGeneration, elapsed < 12,
                  inputs.allSatisfy({ CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= elapsed }) else { return }
            let title = await native.geminiWindowTitle(pid: pid)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let title, title != before, !title.isEmpty else {
                candidate = nil
                matches = 0
                continue
            }
            matches = candidate == title ? matches + 1 : 1
            candidate = title
            guard matches >= 3, elapsed >= 0.8 else { continue }
            guard generation == navigationGeneration, GeminiHistoryStore(root: GeminiHistoryStore.defaultRoot()).contains(reference) else { return }
            GeminiTitles.record(title, for: reference)
            return
        }
    }

    private func openURLs(_ urls: [URL], bundle: String) async -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return false }
        return await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }
}
