import SwiftUI

public struct ContentView: View {
    @ObservedObject var viewModel: AgentHudViewModel

    public init(viewModel: AgentHudViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if viewModel.isMinimized {
                minimizedContent
            } else {
                fullContent
            }
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            Text("Agent HUD")
                .font(.headline)
            Spacer()
            Button(action: { viewModel.toggleMinimized() }) {
                Image(systemName: viewModel.isMinimized ? "plus.circle" : "minus.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var minimizedContent: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.sessions.filter { !$0.isActive || $0.hasUnreadCompletion }) { session in
                Circle()
                    .fill(color(for: session.displayState))
                    .frame(width: 10, height: 10)
                    .help(session.displayTitle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var fullContent: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.sessions) { session in
                SessionRow(session: session, viewModel: viewModel)
            }
            if viewModel.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private func color(for state: AgentState) -> Color {
        switch state {
        case .working, .thinking: return .blue
        case .waitingForInput, .waitingForApproval: return .yellow
        case .completed: return .green
        case .error: return .red
        case .stopped, .idle: return .gray
        case .rateLimited: return .pink
        case .unknown, .starting: return .purple
        }
    }
}

struct SessionRow: View {
    let session: AgentSession
    @ObservedObject var viewModel: AgentHudViewModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: session.displayState))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(session.projectName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(session.agentType.displayName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            viewModel.openProject(session)
        }
        .contextMenu {
            Button("Hide") { viewModel.hideSession(session.id) }
            Button("Open Project") { viewModel.openProject(session) }
        }
    }

    private func color(for state: AgentState) -> Color {
        switch state {
        case .working, .thinking: return .blue
        case .waitingForInput, .waitingForApproval: return .yellow
        case .completed: return .green
        case .error: return .red
        case .stopped, .idle: return .gray
        case .rateLimited: return .pink
        case .unknown, .starting: return .purple
        }
    }
}
