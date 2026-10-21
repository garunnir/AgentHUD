import Foundation

/// One global memo plus one memo per project (Git root or cwd), kept in a single JSON file
/// (port of the Windows MemoStore; same `{"Global", "Projects"}` shape as memos.json there).
public final class MemoStore {
    private struct Contents: Codable {
        var global: String
        var projects: [String: String]
        enum CodingKeys: String, CodingKey {
            case global = "Global"
            case projects = "Projects"
        }
    }

    private let url: URL
    private var contents: Contents

    public init(url: URL) {
        self.url = url
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) }
        contents = stored ?? Contents(global: "", projects: [:])
    }

    public var global: String { contents.global }

    public func project(_ projectPath: String?) -> String? {
        guard let key = Self.key(projectPath) else { return nil }
        return contents.projects[key]
    }

    public func hasProject(_ projectPath: String?) -> Bool { project(projectPath) != nil }

    public func setGlobal(_ text: String) {
        guard contents.global != text else { return }
        contents.global = text
        save()
    }

    public func setProject(_ projectPath: String, _ text: String) {
        guard let key = Self.key(projectPath) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard contents.projects[key] != value else { return }
        contents.projects[key] = value
        save()
    }

    private static func key(_ projectPath: String?) -> String? {
        guard let projectPath, !projectPath.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var path = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(contents) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
