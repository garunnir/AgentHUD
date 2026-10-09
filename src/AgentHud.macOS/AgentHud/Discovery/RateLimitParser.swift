import Foundation

public enum RateLimitParser {
    public static let fallbackDelay: TimeInterval = 3600

    public static func looksLikeUsageLimit(_ text: String) -> Bool {
        let patterns = [
            #"rate.?limit"#, #"usage.?limit"#, #"quota.?exceeded"#,
            #"too many requests"#, #"try again in \d+"#, #"resets? at"#, #"resets? \d+"#
        ]
        let lower = text.lowercased()
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    public static func parseReset(_ text: String, at now: Date) -> Date? {
        // Unix timestamp suffix: |1751234567
        if let unixMatch = text.range(of: #"\|(\d{10,13})"#, options: .regularExpression) {
            let ts = String(text[unixMatch].dropFirst())
            if let seconds = Double(ts) {
                return Date(timeIntervalSince1970: seconds)
            }
        }

        // Relative: "try again in 2 hours 15 minutes"
        if let relative = parseRelative(text) {
            return now.addingTimeInterval(relative)
        }

        // Clock time: "resets 3pm", "try again at 4:34 PM"
        if let clock = parseClockTime(text) {
            return clock
        }

        // With date: "resets Oct 3, 4:30pm"
        if let dated = parseDatedTime(text) {
            return dated
        }

        return nil
    }

    private static func parseRelative(_ text: String) -> TimeInterval? {
        let pattern = #"(\d+)\s*(hour|hr|h|minute|min|m|second|sec|s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return nil }

        var total: TimeInterval = 0
        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let value = Int(text[valueRange]) else { continue }
            let unit = text[unitRange].lowercased()
            switch unit {
            case "hour", "hr", "h": total += Double(value) * 3600
            case "minute", "min", "m": total += Double(value) * 60
            case "second", "sec", "s": total += Double(value)
            default: break
            }
        }
        return total > 0 ? total : nil
    }

    private static func parseClockTime(_ text: String) -> Date? {
        let patterns = [
            #"resets? (\d{1,2}):(\d{2})\s*(am|pm)?"#,
            #"try again at (\d{1,2}):(\d{2})\s*(am|pm)?"#,
            #"resets? (\d{1,2})\s*(am|pm)"#,
            #"try again at (\d{1,2})\s*(am|pm)"#
        ]
        let calendar = Calendar.current
        let now = Date()

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            let groups = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text) }.map { String(text[$0]) }
            guard groups.count >= 2 else { continue }

            var hour = Int(groups[0]) ?? 0
            let minute = groups.count >= 3 && groups[1].count <= 2 ? Int(groups[1]) ?? 0 : 0
            let ampm = groups.last { $0.lowercased() == "am" || $0.lowercased() == "pm" }?.lowercased()

            if ampm == "pm" && hour < 12 { hour += 12 }
            if ampm == "am" && hour == 12 { hour = 0 }

            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            if let date = calendar.date(from: components) {
                if date < now { return calendar.date(byAdding: .day, value: 1, to: date) }
                return date
            }
        }
        return nil
    }

    private static func parseDatedTime(_ text: String) -> Date? {
        let pattern = #"resets? (\w+)\s+(\d{1,2}),?\s*(\d{1,2}):(\d{2})\s*(am|pm)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let monthRange = Range(match.range(at: 1), in: text),
              let dayRange = Range(match.range(at: 2), in: text),
              let hourRange = Range(match.range(at: 3), in: text),
              let minRange = Range(match.range(at: 4), in: text),
              let ampmRange = Range(match.range(at: 5), in: text) else { return nil }

        let monthStr = String(text[monthRange])
        let day = Int(text[dayRange]) ?? 1
        var hour = Int(text[hourRange]) ?? 0
        let minute = Int(text[minRange]) ?? 0
        let ampm = text[ampmRange].lowercased()

        if ampm == "pm" && hour < 12 { hour += 12 }
        if ampm == "am" && hour == 12 { hour = 0 }

        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        guard let month = months[String(monthStr.lowercased().prefix(3))] else { return nil }

        var components = Calendar.current.dateComponents([.year], from: Date())
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)
    }
}
