import SwiftUI
import AppKit

public struct ContentView: View {
    @ObservedObject var viewModel: AgentHudViewModel
    @State private var showSettings = false

    public init(viewModel: AgentHudViewModel) {
        self.viewModel = viewModel
    }

    private var visibleSessions: [AgentSession] {
        viewModel.sessions.filter { !viewModel.hiddenSessionIds.contains($0.id) }
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
            Button(action: { showSettings.toggle() }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsPopover(viewModel: viewModel)
            }
            Button(action: { viewModel.toggleMinimized() }) {
                Image(systemName: viewModel.isMinimized ? "plus.circle" : "minus.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            viewModel.toggleMinimized()
        }
    }

    private var minimizedContent: some View {
        HStack(spacing: 8) {
            ForEach(visibleSessions) { session in
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
            ForEach(visibleSessions) { session in
                SessionRow(session: session, viewModel: viewModel)
            }
            if visibleSessions.isEmpty {
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

struct SettingsPopover: View {
    @ObservedObject var viewModel: AgentHudViewModel

    private let windowChoices = [5, 10, 30, 60, 120, 240, 1440]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.headline)
            Picker("Codex active window", selection: $viewModel.codexActiveWindowMinutes) {
                ForEach(windowChoices, id: \.self) { minutes in
                    Text(minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m").tag(minutes)
                }
            }
            .frame(width: 220)
            if !viewModel.hiddenSessionIds.isEmpty {
                Button("Show hidden sessions (\(viewModel.hiddenSessionIds.count))") {
                    viewModel.showHiddenSessions()
                }
            }
            Divider()
            Button("Quit Agent HUD") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
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
