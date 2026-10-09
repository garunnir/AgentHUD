import SwiftUI

/// One usage gauge line at the bottom of the HUD (mirrors the Windows UsageRow).
struct UsageRow: Identifiable, Equatable {
    let id: String
    let agent: AgentType
    let label: String          // internal: "5h" or "week"
    let usedPercent: Double?   // nil = no bar, text only
    var text: String           // reset time or token summary
    var pacePercent: Double?

    var displayLabel: String { label == "week" ? Localiz.current.string("Usage.Week") : label }
    var remainingPercent: Double { 100 - (usedPercent ?? 0) }
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
            Text(row.text)
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
        }
        .frame(height: 16)
    }

    private func paceTip(_ pace: Double) -> String {
        HudTheme.formatPattern(Localiz.current.string("Usage.PaceTip"), [pace])
    }
}
