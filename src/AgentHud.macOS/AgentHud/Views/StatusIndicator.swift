import SwiftUI

/// Status indicator matching the Windows app: colored dot (pulsing while working),
/// green check for unseen completions, and optional ? / ! symbols for waiting states.
struct StatusIndicator: View {
    let session: AgentSession
    let showWaitingSymbols: Bool

    @State private var pulsing = false

    private var state: AgentState { session.displayState }

    private var isPulsingState: Bool {
        state == .starting || state == .working || state == .thinking
    }

    private var waitingSymbol: String? {
        guard showWaitingSymbols else { return nil }
        switch state {
        case .waitingForInput: return "?"
        case .waitingForApproval: return "!"
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            if state == .completed {
                CheckmarkShape()
                    .stroke(HudTheme.stateColor(.completed), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 9)
            } else if let symbol = waitingSymbol {
                Text(symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(HudTheme.stateColor(state))
            } else {
                Circle()
                    .fill(HudTheme.stateColor(state))
                    .frame(width: 11, height: 11)
                    .opacity(pulsing ? 0.45 : 1)
            }
        }
        .frame(width: 12, height: 18)
        .help(session.statusTip)
        .onAppear { updatePulse() }
        .onChange(of: state) { _, _ in updatePulse() }
    }

    private func updatePulse() {
        if isPulsingState {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        } else {
            withAnimation(.linear(duration: 0)) {
                pulsing = false
            }
        }
    }
}

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 1, y: 5))
        path.addLine(to: CGPoint(x: 4, y: 8))
        path.addLine(to: CGPoint(x: 10, y: 1))
        return path
    }
}
