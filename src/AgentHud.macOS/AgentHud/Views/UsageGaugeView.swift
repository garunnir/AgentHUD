import SwiftUI

/// One usage gauge line at the bottom of the HUD (mirrors the Windows UsageRow).
struct UsageRow: Identifiable, Equatable {
    let id: String
    let agent: AgentType
    let label: String          // internal: "5h" or "week"
    let usedPercent: Double?   // nil = no bar, text only
    var text: String           // reset time or token summary
    var pacePercent: Double?
    /// When this snapshot was recorded. Limits come from local session logs, so the
    /// value can be minutes old; the HUD says so instead of implying it is live.
    var updatedAt: Date?
    private static let staleAfter: TimeInterval = 300

    var displayLabel: String { label == "week" ? Localiz.current.string("Usage.Week") : label }
    var remainingPercent: Double { 100 - (usedPercent ?? 0) }
    /// True once the snapshot is old enough that the real usage may have moved on.
    var isStale: Bool {
        guard let updatedAt else { return false }
        return Date().timeIntervalSince(updatedAt) > Self.staleAfter
    }
    /// "3h 0m" when fresh, "3h 0m · 1h 4m ago" once the snapshot is old.
    var displayText: String {
        guard let updatedAt, isStale, usedPercent != nil else { return text }
        return text.isEmpty ? ageText(now: Date()) : "\(text) · \(ageText(now: Date()))"
    }
    private func ageText(now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(updatedAt ?? now))
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let value = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return HudTheme.formatPattern(Localiz.current.string("Usage.UpdatedAgo"), [value])
    }
}

struct UsageGaugeView: View {
    let row: UsageRow

    var body: some View {
        HStack(spacing: 5) {
            AgentIconView(type: row.agent)
                .frame(width: 14, height: 14)
                .help(row.agent.displayName)
                .allowsHitTesting(false)
            Text(row.displayLabel)
                .font(.system(size: 11))
                .foregroundStyle(HudTheme.dim)
                .frame(width: 34, alignment: .leading)
                .allowsHitTesting(false)
            if row.usedPercent != nil {
                UsageBarView(row: row)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 4)
            }
            Text(row.displayText)
                .font(.system(size: 11))
                .foregroundStyle(HudTheme.secondary)
                .lineLimit(1)
                .allowsHitTesting(false)
        }
    }
}

struct UsageBarView: View {
    let row: UsageRow

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(HudTheme.barTrack)
                RoundedRectangle(cornerRadius: 4)
                    .fill(HudTheme.usageFill(usedPercent: row.usedPercent ?? 0))
                    .frame(width: max(0, geo.size.width * row.remainingPercent / 100))
                if let pace = row.pacePercent {
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2)
                        .offset(x: min(max(geo.size.width * pace / 100 - 1, 0), max(0, geo.size.width - 2)))
                        .help(paceTip(pace))
                }
                                Text("\(Int(row.remainingPercent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
            .help(barTip)
        }
        .frame(height: 16)
    }

    private func paceTip(_ pace: Double) -> String {
        HudTheme.formatPattern(Localiz.current.string("Usage.PaceTip"), [pace])
    }

    private var barTip: String {
        var parts = ["\(Int(row.remainingPercent.rounded()))%"]
        if !row.text.isEmpty { parts.append(row.text) }
        if let updated = row.updatedAt {
            parts.append(HudTheme.formatPattern(Localiz.current.string("Usage.RecordedAt"), [updated.formatted(date: .omitted, time: .shortened)]))
        }
        return parts.joined(separator: " · ")
    }
}
