import Foundation

public final class Localiz {
    public static let english = "en"
    public static let auto = ""

    public struct LanguageOption: Hashable, Sendable {
        public let code: String
        public let name: String
        public init(code: String, name: String) { self.code = code; self.name = name }
    }

    public static let current = Localiz(locale: Locale.current)
    private let table: [String: [String: String]]
    private let languages: [LanguageOption]
    private let systemLanguage: String?
    public private(set) var language: String
    public var languageChoices: [LanguageOption] { [LanguageOption(code: Localiz.auto, name: "System Language")] + languages }
    public var effectiveLanguage: String { language.isEmpty ? (systemLanguage ?? Self.english) : language }

    public init(locale: Locale = .current, language: String = "", table: [String: [String: String]]? = nil) {
        self.table = table ?? Self.loadTable()
        self.languages = Self.loadLanguages(from: self.table)
        var matched: String?
        var candidate: Locale = locale
        while !candidate.identifier.isEmpty {
            if let option = languages.first(where: { $0.code.caseInsensitiveCompare(candidate.identifier) == .orderedSame }) {
                matched = option.code
                break
            }
            if let languageCode = candidate.language.languageCode?.identifier,
               let option = languages.first(where: { $0.code.caseInsensitiveCompare(languageCode) == .orderedSame }) {
                matched = option.code
                break
            }
            candidate = Locale(identifier: candidate.language.languageCode?.identifier ?? "")
            if candidate.identifier.isEmpty { break }
        }
        self.systemLanguage = matched
        self.language = language
    }

    public func string(_ key: String) -> String {
        guard let row = table[key] else { return key }
        if let value = row[effectiveLanguage] { return value }
        if let value = row[Self.english] { return value }
        return key
    }

    public func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), arguments: args)
    }

    private static func loadTable() -> [String: [String: String]] {
        guard let url = Bundle.module.url(forResource: "Strings", withExtension: "tsv"),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(content)
    }

    private static func loadLanguages(from table: [String: [String: String]]) -> [LanguageOption] {
        guard let names = table["Language.Name"] else { return [] }
        return names.map { LanguageOption(code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    private static func parse(_ content: String) -> [String: [String: String]] {
        var header: [String]?
        var table: [String: [String: String]] = [:]
        for line in content.components(separatedBy: .newlines) {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cells = line.components(separatedBy: "\t")
            if header == nil { header = cells; continue }
            guard let header else { continue }
            var row: [String: String] = [:]
            for (index, cell) in cells.enumerated().dropFirst() {
                if index < header.count && !cell.isEmpty { row[header[index]] = unescape(cell) }
            }
            table[cells[0]] = row
        }
        return table
    }

    private static func unescape(_ string: String) -> String {
        guard string.contains("\\") else { return string }
        return string.replacingOccurrences(of: "\\\\", with: "\0")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\0", with: "\\")
    }
}
