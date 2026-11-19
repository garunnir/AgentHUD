import SwiftUI

/// A moving ring means live work. All other states use an equally sized, colored dot.
struct StatusIndicator: View {
    static let diameter: CGFloat = 10
    let session: AgentSession
    var hasRunningDescendants: Bool = false

    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: AgentState { session.displayState }

    var body: some View {
        Group {
            if hasRunningDescendants || SessionListPolicy.isRunning(session) {
                Circle().trim(from: 0.15, to: 0.9)
                    .stroke(HudTheme.stateColor(.working), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 0.85).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = true }
                    .onDisappear { spinning = false }
            } else {
                Circle().fill([.unknown, .idle].contains(state) && session.sourceUnread == true ? Color.blue : HudTheme.stateColor(state))
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .frame(width: 12, height: 18)
        .help(session.statusTip)
    }
}
