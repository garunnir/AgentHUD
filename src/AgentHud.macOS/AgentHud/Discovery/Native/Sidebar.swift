import Foundation

public enum AgentApp: String, CaseIterable, Identifiable, Codable, Sendable {
    case chatGPT, gemini, claude, amp, openCode
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .gemini: "Gemini"
        case .claude: "Claude"
        case .amp: "Amp"
        case .openCode: "OpenCode"
        }
    }
    public var bundleIDs: [String] {
        switch self {
        case .chatGPT: ["com.openai.chat"]
        case .gemini: ["com.google.GeminiMacOS"]
        case .claude: ["com.anthropic.claudefordesktop"]
        case .amp: ["com.ampcode.amp.macos"]
        case .openCode: ["ai.opencode.desktop"]
        }
    }
    public var supportsThreadReading: Bool { self != .chatGPT }
}

public struct SidebarBounds: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func sharesRow(with other: SidebarBounds) -> Bool {
        guard [x, y, width, height, other.x, other.y, other.width, other.height].allSatisfy(\.isFinite),
              width > 0, height > 0, other.width > 0, other.height > 0 else { return false }
        let overlap = min(y + height, other.y + other.height) - max(y, other.y)
        return overlap >= min(height, other.height) * 0.6
    }
}

/// Only the structure of an identified sidebar is captured. No conversation text is needed.
public struct SidebarNode: Sendable {
    public let key: String
    public let role: String
    public let title: String
    public let detail: String
    public let value: String
    public let url: String?
    public let selected: Bool
    public let bounds: SidebarBounds?
    public let children: [SidebarNode]

    public init(_ key: String, role: String = "AXGroup", title: String = "",
                detail: String = "", value: String = "", url: String? = nil, selected: Bool = false,
                bounds: SidebarBounds? = nil, children: [SidebarNode] = []) {
        self.key = key
        self.role = role
        self.title = title
        self.detail = detail
        self.value = value
        self.url = url
        self.selected = selected
        self.bounds = bounds
        self.children = children
    }
    public var labels: [String] {
        let names = role == "AXRow" ? [title, value, detail] : [title, detail, value]
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    public var label: String { labels.first ?? "" }
}

public enum ThreadAction: Sendable, Equatable {
    case accessibility(elementKey: String, url: String?)
    case localCodex(UUID)
}

public struct ThreadItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let app: AgentApp
    public let title: String
    public let selected: Bool
    public let action: ThreadAction
    public let statusMenuKey: String?
    public let isSubagent: Bool

    public var elementKey: String {
        if case let .accessibility(key, _) = action { return key }
        return ""
    }
    public var url: String? {
        if case let .accessibility(_, url) = action { return url }
        return nil
    }

    public init(id: String, app: AgentApp, title: String, elementKey: String,
                url: String?, selected: Bool, statusMenuKey: String? = nil, isSubagent: Bool = false) {
        self.id = id
        self.app = app
        self.title = title
        self.action = .accessibility(elementKey: elementKey, url: url)
        self.selected = selected
        self.statusMenuKey = statusMenuKey
        self.isSubagent = isSubagent
    }

    public init(localCodexID: UUID, title: String) {
        self.id = "codex-local:\(localCodexID.uuidString.lowercased())"
        self.app = .chatGPT
        self.title = title
        self.action = .localCodex(localCodexID)
        self.selected = false
        self.statusMenuKey = nil
        self.isSubagent = false
    }
}

/// Exact structural markers keep links in the conversation out of the list.
public enum SidebarScope {
    public static func childKeys(app: AgentApp, node: SidebarNode) -> [String]? {
        switch app {
        case .chatGPT:
            return nil
        case .gemini:
            guard ["AXOutline", "AXList"].contains(node.role),
                  ["sidebar", "사이드바"].contains(node.label.lowercased()) else { return nil }
        case .claude:
            guard node.role == "AXGroup",
                  ["sidebar", "사이드바"].contains(node.label.lowercased()) else { return nil }
        case .amp:
            guard let boundary = node.children.firstIndex(where: {
                $0.role == "AXSplitter" && ["resize sidebar", "사이드바 크기 조정"].contains($0.label.lowercased())
            }), node.children[..<boundary].contains(where: {
                $0.role == "AXButton" && ["search threads", "스레드 검색"].contains($0.label.lowercased())
            }) else { return nil }
            return node.children[..<boundary].map(\.key)
        case .openCode:
            guard node.children.contains(where: {
                $0.role == "AXButton" && ["toggle sidebar", "사이드바 전환"].contains($0.label.lowercased())
            }) else { return nil }
        }
        return node.children.map(\.key)
    }
}

public enum ThreadExtractor {
    public static func extract(app: AgentApp, sidebar: SidebarNode, generation: String) -> [ThreadItem] {
        guard app.supportsThreadReading else { return [] }
        var candidates: [SidebarNode] = []
        var matchedNames: [String: String] = [:]
        var matchedMenuKeys: [String: String] = [:]
        switch app {
        case .gemini:
            var inChats = false
            for row in flattened(sidebar) where row.role == "AXRow" {
                let descendants = flattened(row)
                if descendants.contains(where: { node in
                    ["AXHeading", "AXButton"].contains(node.role)
                        && node.labels.contains { ["전체", "all", "chats", "채팅"].contains($0.lowercased()) }
                }) {
                    inChats = true
                    continue
                }
                let named: SidebarNode
                if !row.label.isEmpty {
                    named = row
                } else {
                    let buttons = flattened(row).filter { $0.role == "AXButton" && !$0.label.isEmpty }
                    guard Set(buttons.map(\.label)).count == 1, let button = buttons.first else { continue }
                    named = button
                }
                if named.labels.contains(where: { ["전체", "all", "chats", "채팅"].contains($0.lowercased()) }) {
                    inChats = true
                } else if inChats {
                    candidates.append(named)
                }
            }
        case .claude:
            for parent in flattened(sidebar) {
                let directKeys = Set(parent.children.map(\.key))
                let children = unwrapContainers(parent.children)
                let menus = children.filter { $0.role == "AXPopUpButton" }
                // Match all accessibility names: a menu may have a generic title and a specific description.
                for button in children where button.role == "AXButton" {
                    if let name = button.labels.first(where: { buttonName in
                        menus.contains { menu in
                            let wrapped = !directKeys.contains(button.key) || !directKeys.contains(menu.key)
                            if wrapped {
                                guard let buttonBounds = button.bounds, let menuBounds = menu.bounds,
                                      buttonBounds.sharesRow(with: menuBounds) else { return false }
                            }
                            if menu.labels.contains(where: { matchesClaudeSession(button: buttonName, menu: $0) }) {
                                matchedMenuKeys[button.key] = menu.key
                                return true
                            }
                            return false
                        }
                    }) {
                        candidates.append(button)
                        matchedNames[button.key] = menus.filter { $0.key == matchedMenuKeys[button.key] }.flatMap(\.labels)
                            .first(where: { matchesClaudeSession(button: name, menu: $0) }).flatMap(claudeBaseTitle) ?? name
                    }
                }
            }
        case .amp, .openCode:
            candidates = flattened(sidebar).filter { $0.role == "AXLink" && isThreadURL($0.url, app: app) }
        case .chatGPT:
            return []
        }

        var seen = Set<String>()
        return candidates.compactMap { node in
            let label = cleanTitle(matchedNames[node.key] ?? node.label, app: app)
            guard !label.isEmpty else { return nil }
            let ampIdentity = app == .amp ? ampSessionID(node.url).map { "https://ampcode.com/threads/" + $0 } : nil
            let identity = ampIdentity ?? node.url ?? "\(generation):\(node.key)"
            guard seen.insert(identity).inserted else { return nil }
            return ThreadItem(id: "\(app.id):\(identity)", app: app, title: label,
                              elementKey: node.key, url: node.url, selected: node.selected, statusMenuKey: matchedMenuKeys[node.key], isSubagent: app == .amp && ampIsSubagent(node))
        }
    }

    public static func ampIsSubagent(_ node: SidebarNode) -> Bool {
        guard node.role == "AXLink", ampSessionID(node.url) != nil else { return false }
        return node.labels.contains { label in
            let lines = label.components(separatedBy: "\n")
            let tokens = (lines.first ?? "").components(separatedBy: ", ")
            return lines.count >= 2 && ["Orb Executor", "Local Runner", "External Agent"].contains(tokens.first ?? "")
                && tokens.dropFirst().contains("Created by Another Thread")
        }
    }

    public static func ampSessionID
(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), url.scheme == "https", url.host?.lowercased() == "ampcode.com", url.port == nil || url.port == 443,
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              url.pathComponents.count == 3, url.pathComponents[1] == "threads" else { return nil }
        let id = url.pathComponents[2]
        guard ActivityFileStore.validSessionID(id, app: .amp) else { return nil }
        return "T-" + id.dropFirst(2).lowercased()
    }

    /// Amp exposes executor status on the first line and the thread title on following lines.
    /// Unread is not evidence of completion: it can also be a message during execution.
    public static func ampHasUnreadMessages(_ node: SidebarNode) -> Bool? {
        guard node.role == "AXLink", isThreadURL(node.url, app: .amp) else { return nil }
        var recognized = false
        for label in node.labels {
            let lines = label.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 2, !lines[1].isEmpty else { continue }
            let tokens = lines[0].components(separatedBy: ", ")
            guard let first = tokens.first, ["Orb Executor", "Local Runner", "External Agent"].contains(first) else { continue }
            guard tokens.dropFirst().allSatisfy({ ["Executor Connected", "Executor Disconnected", "Created by Another Thread", "Unread Messages"].contains($0) }) else { continue }
            recognized = true
            if tokens.dropFirst().contains("Unread Messages") { return true }
        }
        return recognized ? false : nil
    }

    private static func unwrapContainers(_ nodes: [SidebarNode]) -> [SidebarNode] {
        nodes.flatMap { node in
            if node.role == "AXGroup", node.labels.isEmpty, node.children.count == 1 {
                return unwrapContainers(node.children)
            }
            return [node]
        }
    }

    /// The title comes from the same row's options menu, never from suffix guessing alone.
    public static func claudeActivity(label: String, title: String) -> ThreadActivity? {
        if label == title { return .unknown }
        if label == title + " 실행 중" { return .running }
        if label == title + " 읽지 않은 응답" { return .needsReview }
        return nil
    }

    public static func claudeActivity(labels: [String], title: String) -> ThreadActivity? {
        let states = labels.compactMap { claudeActivity(label: $0, title: title) }
        if states.contains(.running) { return .running }
        if states.contains(.needsReview) { return .needsReview }
        return states.first
    }

    private static func claudeBaseTitle(_ menu: String) -> String? {
        let suffix = "에 대한 더 많은 옵션"
        let prefix = "more options for "
        if menu.hasSuffix(suffix) { return String(menu.dropLast(suffix.count)) }
        if menu.lowercased().hasPrefix(prefix) { return String(menu.dropFirst(prefix.count)) }
        return nil
    }

    private static func matchesClaudeSession(button: String, menu: String) -> Bool {
        guard let base = claudeBaseTitle(menu) else { return false }
        return claudeRowMatchesTitle(button, title: base)
    }
    public static func claudeRowMatchesTitle(_ label: String, title: String) -> Bool {
        if claudeActivity(label: label, title: title) != nil { return true }
        guard !title.isEmpty else { return false }
        let label = label.lowercased(); let title = title.lowercased()
        if label == title { return true }
        guard label.hasPrefix(title) else { return false }
        let suffix = String(label.dropFirst(title.count))
        return [" 병합됨", " 클라우드", " 마감", " merged", " cloud", " closed"].contains { state in
            suffix == state || suffix.hasPrefix(state + " · ")
        }
    }

    private static func flattened(_ node: SidebarNode) -> [SidebarNode] {
        [node] + node.children.flatMap(flattened)
    }

    private static func isThreadURL(_ value: String?, app: AgentApp) -> Bool {
        guard let value, let url = URL(string: value) else { return false }
        switch app {
        case .amp:
            return ampSessionID(value) != nil
        case .openCode:
            return url.scheme == "oc" && url.host == "renderer"
                && url.path.hasPrefix("/server/") && url.path.contains("/session/ses_")
        default:
            return false
        }
    }

    private static func cleanTitle(_ value: String, app: AgentApp) -> String {
        let lines = value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        guard app == .amp else { return lines.joined(separator: " ") }
        if ["Threads", "스레드"].contains(first) || first == "Space" || first.hasPrefix("Space,") { return "" }
        if ["Orb Executor", "Local Runner", "External Agent"].contains(where: { first.hasPrefix($0) }) {
            return lines.dropFirst().joined(separator: " ")
        }
        return lines.joined(separator: " ")
    }
}
