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
    /// True for values read straight from the server: they are only one refresh
    /// interval old, so they are not labelled with an age like a log snapshot is.
    var fromServer = false
    /// Remaining % that the amber warning line marks (<= 0 hides it).
    var warningPercent: Double = 0
    private static let staleAfter: TimeInterval = 300

    var displayLabel: String {
        if label == "week" { return Localiz.current.string("Usage.Week") }
        if label == "month" { return Localiz.current.string("Usage.Month") }
        return label
    }
    var remainingPercent: Double { 100 - (usedPercent ?? 0) }
    /// True once the snapshot is old enough that the real usage may have moved on.
    var isStale: Bool {
        guard let updatedAt, !fromServer else { return false }
        return Date().timeIntervalSince(updatedAt) > Self.staleAfter
    }
    /// "3h 0m" when fresh, "3h 0m · 1h 4m ago" once the snapshot is old.
    var displayText: String {
        guard updatedAt != nil, isStale, usedPercent != nil else { return text }
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
    /// Width of the right-hand time column. Shared by every row so all bars end at
    /// the same x, measured from the widest string any of them shows.
    let timeColumnWidth: CGFloat

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
                .frame(width: timeColumnWidth, alignment: .trailing)
                .allowsHitTesting(false)
        }
    }
}

struct UsageBarView: View {
    let row: UsageRow

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(HudTheme.barTrack)
                RoundedRectangle(cornerRadius: 4)
                    .fill(HudTheme.usageFill(
                        remainingPercent: row.remainingPercent,
                        warningPercent: row.warningPercent
                    ))
                    .frame(width: max(0, width * row.remainingPercent / 100))
                // White marker: where the remaining usage should sit at this point in
                // the window. Details in the tooltip.
                if let pace = row.pacePercent {
                    let marker = markerOffset(pace, width: width)
                    // A 2pt line is hard to hover, so the tip gets a wider target.
                    Color.clear
                        .frame(width: 14, height: 16)
                        .offset(x: marker - 7)
                        .contentShape(Rectangle())
                        .help(paceTip(pace))
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2)
                        .offset(x: marker)
                }
                // Amber marker: configurable warning threshold. When the bar's end
                // crosses it the fill turns amber too.
                if row.warningPercent > 0 {
                    Rectangle()
                        .fill(HudTheme.warning)
                        .frame(width: 2)
                        .offset(x: markerOffset(row.warningPercent, width: width))
                        .help(warningTip)
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

    /// Keeps a 2pt marker inside the bar.
    private func markerOffset(_ percent: Double, width: CGFloat) -> CGFloat {
        min(max(width * percent / 100 - 1, 0), max(0, width - 2))
    }

    private func paceTip(_ pace: Double) -> String {
        HudTheme.formatPattern(Localiz.current.string("Usage.PaceTip"), [Int(pace.rounded())])
    }

    private var warningTip: String {
        HudTheme.formatPattern(Localiz.current.string("Usage.WarningTip"),
                               [Int(row.warningPercent.rounded())])
    }

    private var barTip: String {
        var parts = ["\(Int(row.remainingPercent.rounded()))%"]
        if !row.text.isEmpty { parts.append(row.text) }
        if row.fromServer {
            parts.append(Localiz.current.string("Usage.Live"))
        } else if let updated = row.updatedAt {
            parts.append(HudTheme.formatPattern(
                Localiz.current.string("Usage.RecordedAt"),
                [updated.formatted(date: .omitted, time: .shortened)]
            ))
        }
        if row.warningPercent > 0, row.remainingPercent <= row.warningPercent {
            parts.append(warningTip)
        }
        return parts.joined(separator: " · ")
    }
}
