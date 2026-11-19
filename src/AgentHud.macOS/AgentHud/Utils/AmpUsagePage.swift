import Foundation

struct AmpUsage: Sendable {
    struct Allowance: Sendable {
        let label: String
        let value: Double

        func indicatesLowBalance(at threshold: Double) -> Bool {
            // A lower bound alone cannot confirm that the actual balance is low.
            !label.hasPrefix(">") && !label.hasPrefix("≥") && value <= threshold
        }
    }
    let agent: Allowance
    let orb: Allowance
    let reset: Date
    let observed: Date
}

enum AmpUsagePage: UsageSettingsPage {
    static let serviceName = "Amp"
    static let settingsURL = "https://ampcode.com/settings"

    private static let percent = try! NSRegularExpression(pattern:
        #"^([<>≤≥]?)\s*(\d+(?:\.\d+)?)\s*%\s+remaining$"#, options: .caseInsensitive)
    private static let resetPrefix = "Agent and orb usage resets"

    static func parse(_ tokens: [String], now: Date, zone: TimeZone = .current) -> AmpUsage? {
        let tokens = tokens.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func allowance(_ heading: String) -> AmpUsage.Allowance? {
            let indices = tokens.indices.filter { tokens[$0] == heading }
            guard indices.count == 1, let index = indices.first else { return nil }
            var words: [String] = []
            for token in tokens.dropFirst(index + 1).prefix(4) {
                words.append(token)
                let text = words.joined(separator: " ") as NSString
                guard let match = percent.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { continue }
                let digits = text.substring(with: match.range(at: 2))
                guard let value = Double(digits), (0...100).contains(value) else { return nil }
                return .init(label: text.substring(with: match.range(at: 1)) + digits + "%", value: value)
            }
            return nil
        }

        let resets = tokens.indices.filter { tokens[$0].hasPrefix(resetPrefix) }
        guard let agent = allowance("Agent Usage"), let orb = allowance("Orb Usage"),
              resets.count == 1, let index = resets.first else { return nil }
        var dateText = String(tokens[index].dropFirst(resetPrefix.count)).trimmingCharacters(in: .whitespaces)
        if dateText.isEmpty, index + 1 < tokens.count { dateText = tokens[index + 1] }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.isLenient = false
        for (locale, format) in [("ko_KR", "yyyy년 M월 d일 a h:mm"), ("en_US_POSIX", "MMM d, yyyy, h:mm a"),
                                 ("en_US_POSIX", "MMMM d, yyyy 'at' h:mm a"), ("en_US_POSIX", "M/d/yyyy, h:mm a")] {
            formatter.locale = Locale(identifier: locale)
            formatter.dateFormat = format
            if let reset = formatter.date(from: dateText), reset > now {
                return AmpUsage(agent: agent, orb: orb, reset: reset, observed: now)
            }
        }
        return nil
    }

    static func read(chrome: URL, profile: URL) -> AmpUsage? {
        guard let script = Bundle.module.url(forResource: "amp_usage", withExtension: "rb") else { return nil }
        let worker = Process(), output = Pipe()
        worker.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        worker.arguments = ["--disable-gems", script.path, chrome.path, profile.path]
        worker.standardInput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        worker.standardOutput = output
        do { try worker.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        worker.waitUntilExit()
        guard worker.terminationStatus == 0, data.count <= 4096,
              let tokens = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return parse(tokens, now: Date())
    }
}
