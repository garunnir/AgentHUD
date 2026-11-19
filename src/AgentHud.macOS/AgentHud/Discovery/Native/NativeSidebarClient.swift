import AppKit
import ApplicationServices

struct ScanReply: Sendable {
    let threads: [ThreadItem]
    let message: String?
    var succeeded: Bool = false
}

private enum AccessFailure: LocalizedError {
    case limit, changed, unavailable, unsupportedAction
    var errorDescription: String? {
        switch self {
        case .limit: "목록을 읽는 데 시간이 걸립니다. 앱의 사이드바를 연 뒤 다시 새로고침해 주세요."
        case .changed: "앱의 목록이 바뀌었습니다. 새로고침 후 다시 선택해 주세요."
        case .unavailable: "앱의 사이드바를 열고 새로고침해 주세요."
        case .unsupportedAction: "이 항목은 직접 전환을 지원하지 않습니다. 원본 앱에서 열어 주세요."
        }
    }
}

/// AX references stay on this actor; only value snapshots cross to the main actor.
actor NativeSidebarClient {
    private struct Target {
        let item: ThreadItem
        let element: AXUIElement
        let window: AXUIElement
        let pid: pid_t
        let role: String
        let labels: [String]
        let statusMenu: AXUIElement?
        let statusMenuLabels: [String]
        let statusMenuIdentifier: String?
        let identifier: String?
    }
    private struct CapturedElement {
        let element: AXUIElement
        let node: SidebarNode
        let identifier: String?
    }
    private var targets: [AgentApp: [String: Target]] = [:]

    /// Reports connection and sidebar structure, never titles, full session URLs, or conversation content.
    func diagnose(app: AgentApp, pid: pid_t) -> String {
        guard app.supportsThreadReading else { return "연동 준비 중" }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.3)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
        switch result {
        case .success:
            let count = (value as? [AXUIElement])?.count ?? 0
            var summary = "창 목록 조회 성공 (\(count)개)"
            let budget = ReadBudget()
            do {
                for (index, window) in ((value as? [AXUIElement]) ?? []).enumerated() {
                    if let scope = try findScope(window, app: app, key: "w\(index)", budget: budget) {
                        var elements: [String: CapturedElement] = [:]
                        var nodes: [SidebarNode] = []
                        for (key, element) in scope {
                            nodes.append(try snapshot(element, key: key, budget: budget, elements: &elements))
                        }
                        let captured = elements.values.map(\.node)
                        let roles = Dictionary(grouping: captured, by: \.role)
                            .map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ", ")
                        summary += "\n  사이드바 \(captured.count)개 요소 (\(roles))"
                        summary += "\n  이름 속성 title \(captured.filter { !$0.title.isEmpty }.count), description \(captured.filter { !$0.detail.isEmpty }.count), value \(captured.filter { !$0.value.isEmpty }.count)"
                        let urls = captured.compactMap { $0.url }.compactMap(URL.init(string:))
                        let shapes = Set(urls.map { url in
                            "\(url.scheme ?? "relative")://\(url.host ?? "")/\(url.path.split(separator: "/").first.map(String.init) ?? "") / session=\(url.path.contains("/session/"))"
                        }).sorted().joined(separator: "; ")
                        summary += "\n  링크 URL \(urls.count)개: \(shapes)"
                        return summary
                    }
                }
                return summary + " / 사이드바 경계 없음"
            } catch {
                return summary + " / " + error.localizedDescription
            }
        case .apiDisabled:
            return "macOS가 접근을 거부함 (AX \(result.rawValue))"
        case .cannotComplete:
            return "앱 응답을 받지 못함 (AX \(result.rawValue))"
        default:
            return "창 목록 조회 실패 (AX \(result.rawValue))"
        }
    }

    func scan(app: AgentApp, pid: pid_t) -> ScanReply {
        let previousTargets = targets[app] ?? [:]
        targets[app] = [:]
        // Unsupported providers must be excluded before constructing any AX root.
        guard app.supportsThreadReading, AXIsProcessTrusted() else {
            return ScanReply(threads: [], message: "접근성 권한을 확인해 주세요.")
        }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let budget = ReadBudget()
        let generation = UUID().uuidString
        do {
            let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            guard !windows.isEmpty else { throw AccessFailure.unavailable }
            for (index, window) in windows.enumerated() {
                if let scope = try findScope(window, app: app, key: "w\(index)", budget: budget) {
                    var elements: [String: CapturedElement] = [:]
                    var children: [SidebarNode] = []
                    for (key, element) in scope {
                        children.append(try snapshot(element, key: key, budget: budget, elements: &elements))
                    }
                    let extracted = ThreadExtractor.extract(
                        app: app, sidebar: SidebarNode("sidebar", children: children), generation: generation
                    )
                    var appTargets: [String: Target] = [:]
                    var items: [ThreadItem] = []
                    for original in extracted {
                        var item = original
                        try budget.check()
                        guard let captured = elements[item.elementKey] else { continue }
                        // Preserve row identity only for the same AX element and matching metadata.
                        // Never map a new row by title or position alone.
                        if item.url == nil {
                            for previous in previousTargets.values {
                                guard previous.pid == pid, CFEqual(previous.element, captured.element),
                                      previous.role == captured.node.role, labelsMatch(captured.node, target: previous),
                                      previous.identifier == captured.identifier, previous.item.title == item.title else { continue }
                                item = ThreadItem(id: previous.item.id, app: item.app, title: item.title,
                                                  elementKey: item.elementKey, url: item.url, selected: item.selected,
                                                  statusMenuKey: item.statusMenuKey, isSubagent: item.isSubagent)
                                break
                            }
                        }
                        items.append(item)
                        appTargets[item.id] = Target(item: item, element: captured.element, window: window, pid: pid,
                                                     role: captured.node.role, labels: captured.node.labels,
                                                     statusMenu: item.statusMenuKey.flatMap { elements[$0]?.element },
                                                     statusMenuLabels: item.statusMenuKey.flatMap { elements[$0]?.node.labels } ?? [],
                                                     statusMenuIdentifier: item.statusMenuKey.flatMap { elements[$0]?.identifier },
                                                     identifier: captured.identifier)
                    }
                    targets[app] = appTargets

                    return ScanReply(threads: items, message: items.isEmpty ? "불러온 스레드가 없습니다. 원본 앱에서 사이드바를 확인해 주세요." : nil, succeeded: true)
                }
            }
            throw AccessFailure.unavailable
        } catch {
            // Short-lived native list failures must not erase still-valid, revalidated AX targets.
            targets[app] = [.amp, .gemini].contains(app) ? previousTargets.filter { $0.value.pid == pid } : [:]
            return ScanReply(threads: [], message: error.localizedDescription)
        }
    }

    /// Re-read only already identified sidebar links, without opening chats or changing navigation targets.
    func nativeActivityStates(app: AgentApp, pid: pid_t) -> [String: ThreadActivity] {
        guard [.amp, .claude].contains(app), AXIsProcessTrusted(), let process = NSRunningApplication(processIdentifier: pid),
              !process.isTerminated, app.bundleIDs.contains(process.bundleIdentifier ?? "") else { return [:] }
        let budget = ReadBudget(seconds: 0.75)
        var result: [String: ThreadActivity] = [:]
        for target in (targets[app] ?? [:]).values.prefix(200) {
            guard (try? budget.check()) != nil else { break }
            var livePID: pid_t = 0
            guard target.pid == pid, AXUIElementGetPid(target.element, &livePID) == .success, livePID == pid else { continue }
            let node = metadata(target.element, key: target.item.elementKey, includeValue: true)
            guard node.role == target.role, node.url == target.item.url, labelsMatch(node, target: target),
                  stringAttribute(target.element, kAXIdentifierAttribute) == target.identifier else { continue }
            if app == .amp {
                if let unread = ThreadExtractor.ampHasUnreadMessages(node) { result[target.item.id] = unread ? .unread : .unknown }
            } else if let state = ThreadExtractor.claudeActivity(labels: node.labels, title: target.item.title) {
                result[target.item.id] = state
            }
        }
        return result
    }

    func confirmClaudeLocalID(_ id: String, pid: pid_t) async -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        for _ in 0..<20 {
            for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                if claudeDesktopID(window: window) == id,
                AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success,
                claudeDesktopID(window: window) == id { return true }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    private func claudeDesktopID(window: AXUIElement) -> String? {
        let budget = ReadBudget(seconds: 0.6)
        guard let element = try? findControl(window, budget: budget, matching: { element, role in
            role == "AXWebArea" && ClaudeDesktopLink.desktopID(from: self.urlAttribute(element)) != nil
        }) else { return nil }
        return ClaudeDesktopLink.desktopID(from: urlAttribute(element))
    }

    struct ClaudeActivity: Sendable {
        var working: Set<String> = []
        var viewed: Set<String> = []
    }
    func claudeDesktopActivity(pid: pid_t) async -> ClaudeActivity {
        guard AXIsProcessTrusted(), let process = NSRunningApplication(processIdentifier: pid),
              !process.isTerminated, process.bundleIdentifier == "com.anthropic.claudefordesktop" else { return ClaudeActivity() }
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let focused = attribute(root, kAXFocusedWindowAttribute)
        var result = ClaudeActivity()
        for window in (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(5) {
            let budget = ReadBudget(seconds: 0.75)
            do {
                guard let web = try findControl(window, budget: budget, matching: { element, role in
                    role == "AXWebArea" && ClaudeDesktopLink.desktopID(from: self.urlAttribute(element)) != nil
                }), let id = ClaudeDesktopLink.desktopID(from: urlAttribute(web)) else { continue }
                if frontmost == pid, let focused, CFEqual(focused, window) { result.viewed.insert(id) }
                if let editor = try findControl(web, budget: budget, matching: { element, role in
                    role == kAXTextAreaRole && self.controlLabels(element).contains(where: { ["프롬프트", "Prompt"].contains($0) })
                }) {
                    var ancestor = editor
                    for _ in 0..<2 {
                        guard let raw = attribute(ancestor, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
                        ancestor = unsafeBitCast(raw, to: AXUIElement.self)
                        if try findControl(ancestor, budget: budget, matching: { element, role in
                            role == kAXButtonRole && self.controlLabels(element).contains(where: { ["중지", "Stop", "Stop response", "Stop generating"].contains($0) })
                                && self.attribute(element, kAXEnabledAttribute) as? Bool == true
                        }) != nil, ClaudeDesktopLink.desktopID(from: urlAttribute(web)) == id { result.working.insert(id); break }
                    }
                }
            } catch { continue }
        }
        return result
    }

    /// Require a still-live desktop sidebar before using a companion local cache.
    func hasLiveSidebar(app: AgentApp, pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(), let process = NSRunningApplication(processIdentifier: pid),
              !process.isTerminated, app.bundleIDs.contains(process.bundleIdentifier ?? "") else { return false }
        for target in (targets[app] ?? [:]).values.prefix(5) where target.pid == pid {
            let node = metadata(target.element, key: target.item.elementKey, includeValue: true)
            if node.role == target.role && labelsMatch(node, target: target)
                && stringAttribute(target.element, kAXIdentifierAttribute) == target.identifier { return true }
        }
        // AX row references can expire between full sidebar scans. Recheck the
        // bounded sidebar structure without requiring every historical row to load.
        let root = AXUIElementCreateApplication(pid)
        let budget = ReadBudget(seconds: 2)
        for (index, window) in (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).enumerated() {
            do {
                if let scope = try findScope(window, app: app, key: "w\(index)", budget: budget), !scope.isEmpty { return true }
            } catch { return false }
        }
        return false
    }

    /// Current Amp thread only: canonical WebArea URL + its real message composer Stop control.
    /// Sidebar unread, executor connection, global running counts and title text are not execution evidence.
    func ampRunningSessionIDs(pid: pid_t) -> Set<String> {
        guard AXIsProcessTrusted(), let process = NSRunningApplication(processIdentifier: pid),
              process.bundleIdentifier == AgentApp.amp.bundleIDs.first, !process.isTerminated else { return [] }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let budget = ReadBudget(seconds: 0.75)
        var ids = Set<String>()
        for window in attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            do {
                guard let web = try findControl(window, budget: budget, matching: { element, role in
                    role == "AXWebArea" && ThreadExtractor.ampSessionID(self.urlAttribute(element)) != nil
                }), let id = ThreadExtractor.ampSessionID(urlAttribute(web)),
                let editor = try findControl(web, budget: budget, matching: { _, role in role == kAXTextAreaRole }),
                let parentValue = attribute(editor, kAXParentAttribute), CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { continue }
                let composer = unsafeBitCast(parentValue, to: AXUIElement.self)
                guard stringAttribute(composer, kAXRoleAttribute) == kAXGroupRole,
                controlLabels(composer).contains("Message composer"),
                try findControl(composer, budget: budget, matching: { element, role in
                    role == kAXButtonRole && self.controlLabels(element).contains("Stop agent")
                        && self.attribute(element, kAXEnabledAttribute) as? Bool == true
                }) != nil else { continue }
                guard ThreadExtractor.ampSessionID(urlAttribute(web)) == id else { continue }
                ids.insert(id)
            } catch { break }
        }
        return ids
    }

    /// Gemini 1.144.7 exposes stop_button but no canonical selected chat ID. Report only window-level work.
    /// Native windows that publish their document URL can supply titles without navigation.
    func geminiDocumentTitles(pid: pid_t) -> [String: String] {
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == "com.google.GeminiMacOS", !app.isTerminated else { return [:] }
        var results: [String: String] = [:]
        for target in (targets[.gemini] ?? [:]).values where target.pid == pid {
            guard let identifier = target.identifier, identifier.range(of: #"^c_[0-9a-f]{16}$"#, options: .regularExpression) != nil,
                  stringAttribute(target.element, kAXIdentifierAttribute) == identifier,
                  labelsMatch(metadata(target.element, key: target.item.elementKey, includeValue: true), target: target) else { continue }
            results[identifier] = target.item.title
        }
        for window in (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(12) {
            guard let id = geminiDocumentID(window), let title = geminiTitle(of: window),
                  !title.isEmpty, geminiDocumentID(window) == id else { continue }
            results[id] = title
        }
        return results
    }

    /// Only the focused native Gemini document window. Never reads conversation controls.
    func geminiWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == "com.google.GeminiMacOS", !app.isTerminated else { return nil }
        let root = AXUIElementCreateApplication(pid)
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let raw = attribute(root, name), CFGetTypeID(raw) == AXUIElementGetTypeID(),
               let title = geminiTitle(of: unsafeBitCast(raw, to: AXUIElement.self)) { return title }
        }
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.count == 1 ? geminiTitle(of: windows[0]) : nil
    }

    private func geminiTitle(of window: AXUIElement) -> String? {
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { stringAttribute(window, $0) }
        if let title = labels.first(where: { $0.hasPrefix("Gemini - ") }) {
            return String(title.dropFirst("Gemini - ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return labels.contains("Gemini") ? "" : nil
    }

    /// Bind Stop to a document only if this same window still has the same exact route.
    func geminiResponseWindows(pid: pid_t) -> (ids: Set<String>, unidentifiedWindowTitles: [String?]) {
        guard AXIsProcessTrusted(), let process = NSRunningApplication(processIdentifier: pid),
              process.bundleIdentifier == AgentApp.gemini.bundleIDs.first, !process.isTerminated else { return ([], []) }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let budget = ReadBudget(seconds: 0.75)
        var ids = Set<String>(), unidentifiedWindowTitles: [String?] = []
        for window in (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(12) {
            let before = geminiDocumentID(window)
            let title = geminiTitle(of: window)
            do {
                guard try findControl(window, budget: budget, matching: { element, role in
                    role == kAXButtonRole && self.stringAttribute(element, kAXIdentifierAttribute) == "stop_button"
                        && self.attribute(element, kAXEnabledAttribute) as? Bool == true
                }) != nil else { continue }
                if let id = before, geminiDocumentID(window) == id { ids.insert(id) }
                else { unidentifiedWindowTitles.append(title == geminiTitle(of: window) ? title : nil) }
            } catch { break }
        }
        return (ids, unidentifiedWindowTitles)
    }

    private func geminiDocumentID(_ window: AXUIElement) -> String? {
        for name in [kAXDocumentAttribute, kAXURLAttribute] {
            let raw = attribute(window, name)
            let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
            if let url, let id = GeminiConversationReference.documentID(url) { return id }
        }
        return nil
    }

    private func urlAttribute(_ element: AXUIElement) -> String? {
        (attribute(element, kAXURLAttribute) as? URL)?.absoluteString ?? stringAttribute(element, kAXURLAttribute)
    }

    private func controlLabels(_ element: AXUIElement) -> [String] {
        [stringAttribute(element, kAXTitleAttribute), stringAttribute(element, kAXDescriptionAttribute)].compactMap { $0 }
    }

    /// Traverse control structure only. Skip message text, editors, list rows and links before reading labels.
    private func findControl(_ element: AXUIElement, budget: ReadBudget, depth: Int = 0,
                             matching: (AXUIElement, String) -> Bool) throws -> AXUIElement? {
        try budget.visit(depth: depth)
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        if matching(element, role) { return element }
        if [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, kAXRowRole, kAXListRole,
            kAXOutlineRole, "AXLink", "AXHeading"].contains(role) { return nil }
        if [kAXButtonRole, kAXPopUpButtonRole, kAXImageRole].contains(role) { return nil }
        for child in childElements(element) {
            if let match = try findControl(child, budget: budget, depth: depth + 1, matching: matching) { return match }
        }
        return nil
    }

    private func labelsMatch(_ node: SidebarNode, target: Target) -> Bool {
        if target.item.app == .amp { return node.role == "AXLink" && node.url == target.item.url }
        guard target.item.app == .claude else { return node.labels == target.labels }
        // Revalidate the original same-row menu so a renamed/recycled button is never mistaken for status.
        guard let menu = target.statusMenu else { return false }
        var menuPID: pid_t = 0
        guard AXUIElementGetPid(menu, &menuPID) == .success, menuPID == target.pid else { return false }
        let liveMenu = metadata(menu, key: "status-menu", includeValue: true)
        guard liveMenu.role == "AXPopUpButton", liveMenu.labels == target.statusMenuLabels,
              stringAttribute(menu, kAXIdentifierAttribute) == target.statusMenuIdentifier,
              let buttonBounds = node.bounds, let menuBounds = liveMenu.bounds,
              buttonBounds.sharesRow(with: menuBounds) else { return false }
        if node.labels == target.labels { return true }
        return node.labels.contains { ThreadExtractor.claudeRowMatchesTitle($0, title: target.item.title) }
            && target.labels.contains { ThreadExtractor.claudeRowMatchesTitle($0, title: target.item.title) }
    }

func selectKnown(id: String, app: AgentApp, pid: pid_t) -> Bool {
    guard let item = targets[app]?[id]?.item else { return false }
    do { try select(item, pid: pid); return true } catch { return false }
}

func select(_ item: ThreadItem, pid: pid_t) throws {
        guard item.app.supportsThreadReading, AXIsProcessTrusted(),
              let target = targets[item.app]?[item.id], target.pid == pid else {
            throw AccessFailure.changed
        }
        var livePID: pid_t = 0
        guard AXUIElementGetPid(target.element, &livePID) == .success, livePID == pid else {
            throw AccessFailure.changed
        }
        let current = metadata(target.element, key: item.elementKey, includeValue: true)
        guard current.role == target.role, labelsMatch(current, target: target),
              current.url == item.url,
              stringAttribute(target.element, kAXIdentifierAttribute) == target.identifier else {
            throw AccessFailure.changed
        }
        // Some web-backed apps implement AXPress without advertising it in their action list.
        var result = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
        if result == .actionUnsupported, target.role == kAXRowRole {
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(target.element, kAXSelectedAttribute as CFString, &settable) == .success,
                  settable.boolValue else { throw AccessFailure.unsupportedAction }
            result = AXUIElementSetAttributeValue(target.element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        }
        if result == .actionUnsupported || result == .notImplemented { throw AccessFailure.unsupportedAction }
        guard result == .success else { throw AccessFailure.changed }
        AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
    }

    private func findScope(_ element: AXUIElement, app: AgentApp, key: String,
                           budget: ReadBudget, depth: Int = 0) throws -> [(String, AXUIElement)]? {
        try budget.visit(depth: depth)
        let node = metadata(element, key: key)
        if ["AXStaticText", "AXTextArea", "AXTextField", "AXButton", "AXPopUpButton", "AXLink"].contains(node.role) { return nil }
        let children = childElements(element)
        let entries = try children.enumerated().map { index, child -> (String, AXUIElement, SidebarNode) in
            try budget.check()
            let childKey = "\(key).\(index)"
            return (childKey, child, metadata(child, key: childKey))
        }
        let probe = SidebarNode(key, role: node.role, title: node.title, detail: node.detail,
                                children: entries.map { $0.2 })
        if let keys = SidebarScope.childKeys(app: app, node: probe) {
            let accepted = Set(keys)
            return entries.filter { accepted.contains($0.0) }.map { ($0.0, $0.1) }
        }
        for (childKey, child, _) in entries {
            if let scope = try findScope(child, app: app, key: childKey, budget: budget, depth: depth + 1) {
                return scope
            }
        }
        return nil
    }

    private func snapshot(_ element: AXUIElement, key: String, budget: ReadBudget,
                          elements: inout [String: CapturedElement], depth: Int = 0) throws -> SidebarNode {
        try budget.visit(depth: depth)
        let node = metadata(element, key: key, includeValue: true)
        elements[key] = CapturedElement(element: element, node: node,
                                        identifier: stringAttribute(element, kAXIdentifierAttribute))
        let skipChildren = ["AXStaticText", "AXTextArea", "AXTextField", "AXPopUpButton"].contains(node.role)
        let children = try (skipChildren ? [] : childElements(element)).enumerated().map { index, child in
            try snapshot(child, key: "\(key).\(index)", budget: budget, elements: &elements, depth: depth + 1)
        }
        return SidebarNode(key, role: node.role, title: node.title, detail: node.detail, value: node.value,
                           url: node.url, selected: node.selected, bounds: node.bounds, children: children)
    }

    private func metadata(_ element: AXUIElement, key: String, includeValue: Bool = false) -> SidebarNode {
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        // Static text and editable values are intentionally excluded.
        let readsLabel = !["AXStaticText", "AXTextArea", "AXTextField", "AXWebArea"].contains(role)
        let title = readsLabel ? stringAttribute(element, kAXTitleAttribute) ?? "" : ""
        let detail = readsLabel ? stringAttribute(element, kAXDescriptionAttribute) ?? "" : ""
        // Value is only read inside an identified sidebar or when revalidating its selected target.
        let value = includeValue && ["AXRow", "AXButton", "AXPopUpButton"].contains(role)
            ? stringAttribute(element, kAXValueAttribute) ?? "" : ""
        var url: String?
        if role == "AXLink" {
            url = (attribute(element, kAXURLAttribute) as? URL)?.absoluteString
                ?? stringAttribute(element, kAXURLAttribute)
                ?? stringAttribute(element, kAXValueAttribute)
        }
        let bounds = includeValue && ["AXButton", "AXPopUpButton"].contains(role) ? elementBounds(element) : nil
        return SidebarNode(key, role: role, title: title, detail: detail, value: value, url: url,
                           selected: attribute(element, kAXSelectedAttribute) as? Bool ?? false, bounds: bounds)
    }

    private func elementBounds(_ element: AXUIElement) -> SidebarBounds? {
        guard let position = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return SidebarBounds(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        // AX timeouts apply to this exact object, not its child elements.
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        (attribute(element, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func childElements(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }


}

private final class ReadBudget {
    private let deadline: TimeInterval
    init(seconds: TimeInterval = 5) { deadline = ProcessInfo.processInfo.systemUptime + seconds }
    private var visits = 0
    func check() throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw AccessFailure.limit }
    }
    func visit(depth: Int) throws {
        try check()
        visits += 1
        guard visits <= 2_000, depth <= 40 else { throw AccessFailure.limit }
    }
}
