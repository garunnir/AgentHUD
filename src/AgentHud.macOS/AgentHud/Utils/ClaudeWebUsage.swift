import Foundation

enum ClaudeUsagePage {
    static let settingsURL = "https://claude.ai/settings/usage"

    struct Meter {
        let title: String
        let used: Double
        var resetsAt: Date? = nil
    }

    private static let weeklyNames: Set<String> = ["이번 주", "this week", "all models", "모든 모델"]
    private static let koreanDays = ["일", "월", "화", "수", "목", "금", "토"]
    private static let englishDays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let koreanReset = try! NSRegularExpression(pattern:
        #"^\(?([일월화수목금토])(?:요일)?\)?\s*(오전|오후)?\s*(\d{1,2}):(\d{2})\s*에\s*초기화$"#)
    private static let englishReset = try! NSRegularExpression(pattern:
        #"^resets?\s+(?:on\s+)?([a-z]+)\.?[,]?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#)

    static func weeklyReset(in labels: [String], now: Date, calendar: Calendar = .current) -> Date? {
        var dates = Set<Date>()
        for label in labels {
            let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() as NSString
            let range = NSRange(location: 0, length: text.length)
            guard let match = koreanReset.firstMatch(in: text as String, range: range)
                    ?? englishReset.firstMatch(in: text as String, range: range) else { continue }
            func group(_ index: Int) -> String {
                let part = match.range(at: index)
                return part.location == NSNotFound ? "" : text.substring(with: part)
            }
            let korean = koreanDays.contains(group(1))
            let weekday = korean ? koreanDays.firstIndex(of: group(1)) : englishDays.firstIndex {
                $0 == group(1) || String($0.prefix(3)) == group(1)
            }
            let period = group(korean ? 2 : 4)
            guard let weekday, var hour = Int(group(korean ? 3 : 2)) else { continue }
            let minutes = group(korean ? 4 : 3)
            guard let minute = Int(minutes.isEmpty ? "0" : minutes), (0...59).contains(minute) else { continue }
            if period.isEmpty {
                guard !minutes.isEmpty, (0...23).contains(hour) else { continue }
            } else {
                guard (1...12).contains(hour) else { continue }
                hour = hour % 12 + (["오후", "pm"].contains(period) ? 12 : 0)
            }
            let components = DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday + 1)
            if let date = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) { dates.insert(date) }
        }
        return dates.count == 1 ? dates.first : nil
    }

    static func snapshot(meters: [Meter], heading: Bool, fresh: Bool, now: Date) -> ClaudeLimitSnapshot? {
        guard heading, fresh else { return nil }
        func window(_ names: Set<String>, minutes: Int) -> LimitWindow? {
            let matches = meters.filter { names.contains($0.title.lowercased()) }
            guard matches.count == 1, let meter = matches.first, (0...100).contains(meter.used) else { return nil }
            return LimitWindow(usedPercent: meter.used, resetsAt: meter.resetsAt, windowMinutes: minutes)
        }
        guard let week = window(weeklyNames, minutes: 10080) else { return nil }
        return ClaudeLimitSnapshot(source: .usageApi,
                                  fiveHour: window(["current session", "현재 세션"], minutes: 300),
                                  sevenDay: week, updatedAt: now)
    }

}
