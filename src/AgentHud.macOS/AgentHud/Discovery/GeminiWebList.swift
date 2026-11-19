import AppKit
import ApplicationServices

/// Reads conversation links from the signed-in Chrome profile's Gemini home page.
enum GeminiWebList {
    static let marker = "agenthud-title-list"
    static let address = "https://gemini.google.com/app#" + marker

    private static func components(_ url: URL) -> [String]? {
        guard url.scheme == "https", url.host == "gemini.google.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "u", parts[1].utf8.allSatisfy({ (48...57).contains($0) }) {
            parts.removeFirst(2)
        }
        return parts
    }
    static func isHome(_ url: URL) -> Bool {
        components(url) == ["app"] && (url.fragment == nil || url.fragment == marker)
    }
    static func serverID(_ url: URL) -> String? {
        guard let parts = components(url), parts.count == 2, parts[0] == "app", url.fragment == nil,
              parts[1].range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil else { return nil }
        return "c_" + parts[1]
    }
    private static func attribute(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success else { return nil }
        return value
    }
    private static func url(_ e: AXUIElement, key: String = kAXURLAttribute) -> URL? {
        let raw = attribute(e, key)
        return raw as? URL ?? (raw as? String).flatMap(URL.init(string:))
    }
    private static func page(in window: AXUIElement, deadline: TimeInterval) -> AXUIElement? {
        var stack = [window]
        let skip = ["AXToolbar","AXTabGroup","AXTextArea","AXTextField","AXStaticText","AXImage","AXButton"]
        for _ in 0..<160 {
            guard let node = stack.popLast(), ProcessInfo.processInfo.systemUptime < deadline else { break }
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" { return node }
            if !skip.contains(role), let children = attribute(node,kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
        return nil
    }
    static func titles(for ids: Set<String>) -> [String:String] {
        guard AXIsProcessTrusted(), !ids.isEmpty,
              let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else { return [:] }
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var titles: [String:String] = [:]
        var ambiguous = Set<String>()
        for window in windows {
            let location = url(window, key: kAXDocumentAttribute) ?? url(window)
            if let location, !isHome(location) { continue }
            let name = attribute(window, kAXTitleAttribute) as? String ?? ""
            guard location.map(isHome) == true || name.localizedCaseInsensitiveContains("Gemini"),
                  let page = page(in: window, deadline: deadline), let pageURL = url(page), isHome(pageURL) else { continue }
            let query: [String:Any] = ["AXSearchKey":"AXLinkSearchKey","AXResultsLimit":400,"AXDirection":"AXDirectionNext"]
            var hits: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(page, "AXUIElementsForSearchPredicate" as CFString,
                    query as CFDictionary, &hits) == .success, let links = hits as? [AXUIElement] else { continue }
            var local: [String:String] = [:]
            for link in links {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                guard let address = url(link), let id = serverID(address), ids.contains(id) else { continue }
                let label = [kAXTitleAttribute,kAXDescriptionAttribute].compactMap { attribute(link,$0) as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty && $0.count <= 512 }
                if let label {
                    if let old = local[id] ?? titles[id], old != label { ambiguous.insert(id) }
                    local[id] = label
                }
            }
            guard url(page) == pageURL else { continue }
            titles.merge(local) { first,_ in first }
        }
        for id in ambiguous { titles[id] = nil }
        return titles
    }

}
