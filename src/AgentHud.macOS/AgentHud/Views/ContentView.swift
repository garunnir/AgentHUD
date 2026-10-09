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
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(HudTheme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HudTheme.border, lineWidth: 1)
        )
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("AGENTS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HudTheme.dim)
            Text("\(visibleSessions.count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: { showSettings.toggle() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(HudTheme.dim)
            .help(Localiz.current.string("Main.Settings"))
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsPopover(viewModel: viewModel)
            }
            Button(action: { viewModel.toggleMinimized() }) {
                Image(systemName: viewModel.isMinimized ? "plus" : "minus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(HudTheme.dim)
            .help(Localiz.current.string("Main.Minimize"))
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("×")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(HudTheme.dim)
            .help(Localiz.current.string("Common.Close"))
        }
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            viewModel.toggleMinimized()
        }
    }

    private var minimizedContent: some View {
        HStack(spacing: 4) {
            ForEach(visibleSessions) { session in
                StatusIndicator(session: session, showWaitingSymbols: viewModel.showWaitingSymbols)
            }
        }
    }

    private var fullContent: some View {
        VStack(spacing: 0) {
            if visibleSessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(HudTheme.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(visibleSessions) { session in
                    SessionRow(session: session, viewModel: viewModel)
                }
            }
            usageSection
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        let rows = viewModel.buildUsageRows()
        if !rows.isEmpty {
            Divider()
                .overlay(Color.white.opacity(0.1))
                .padding(.vertical, 6)
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    UsageGaugeView(row: row)
                }
            }
        }
    }
}

struct SettingsPopover: View {
    @ObservedObject var viewModel: AgentHudViewModel

    private let windowChoices = [5, 10, 30, 60, 120, 240, 1440]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Localiz.current.string("Main.Settings"))
                .font(.headline)
            Picker("Codex active window", selection: $viewModel.codexActiveWindowMinutes) {
                ForEach(windowChoices, id: \.self) { minutes in
                    Text(minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m").tag(minutes)
                }
            }
            .frame(width: 220)
            Toggle(isOn: $viewModel.showWaitingSymbols) {
                Text("Show waiting states as symbols (? / !)")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            if !viewModel.hiddenSessionIds.isEmpty {
                Button(HudTheme.formatPattern(Localiz.current.string("Main.ShowHidden"), [viewModel.hiddenSessionIds.count])) {
                    viewModel.showHiddenSessions()
                }
            }
            Divider()
            Button("Quit Agent HUD") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}

struct SessionRow: View {
    let session: AgentSession
    @ObservedObject var viewModel: AgentHudViewModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            StatusIndicator(session: session, showWaitingSymbols: viewModel.showWaitingSymbols)
            AgentIconView(type: session.agentType)
                .frame(width: 16, height: 16)
                .help(session.agentType.displayName)
            Text(session.projectName)
                .font(.system(size: 12))
                .foregroundStyle(HudTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 92, alignment: .leading)
            Text(session.displayTitle)
                .font(.system(size: 12))
                .foregroundStyle(HudTheme.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                Button(action: { viewModel.hideSession(session.id) }) {
                    Text("×")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(HudTheme.dim)
                .help(Localiz.current.string("Main.Dismiss"))
            } else {
                Text(session.displayStateName)
                    .font(.system(size: 11))
                    .foregroundStyle(HudTheme.secondary)
                    .lineLimit(1)
                    .help(session.statusTip)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            viewModel.acknowledgeCompletion(session.id)
            viewModel.openProject(session)
        }
        .contextMenu {
            Button(Localiz.current.string("Main.Dismiss")) { viewModel.hideSession(session.id) }
            Button("Open Project") { viewModel.openProject(session) }
        }
    }
}
