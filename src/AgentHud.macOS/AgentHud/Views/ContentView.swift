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
        // Minimized mode shrinks the padding to a compact bar (Windows: 4,2).
        .padding(viewModel.isMinimized
                 ? EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
                 : EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
        .frame(maxWidth: viewModel.isMinimized ? nil : .infinity,
               maxHeight: .infinity,
               alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: viewModel.isMinimized ? 10 : 14, style: .continuous)
                .fill(HudTheme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: viewModel.isMinimized ? 10 : 14, style: .continuous)
                .stroke(HudTheme.border, lineWidth: 1)
        )
        // Minimized mode sizes to the dots row; full mode keeps the fixed panel width.
        .frame(width: viewModel.isMinimized ? nil : 320)
        .background(WindowConfigurator(minimized: viewModel.isMinimized))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("AGENTS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HudTheme.dim)
                .allowsHitTesting(false)
            Text("\(visibleSessions.count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .allowsHitTesting(false)
            Spacer()
            HeaderButton(symbol: "gearshape", help: Localiz.current.string("Main.Settings")) {
                showSettings.toggle()
            }
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsPopover(viewModel: viewModel)
            }
            HeaderButton(symbol: viewModel.isMinimized ? "plus" : "minus",
                         help: Localiz.current.string("Main.Minimize")) {
                viewModel.toggleMinimized()
            }
            HeaderButton(text: "×", help: Localiz.current.string("Common.Close")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.bottom, viewModel.isMinimized ? 0 : 8)
        // Drag the window from anywhere on the header; double-click toggles minimized.
        .background(WindowDragHandle { viewModel.toggleMinimized() })
    }

    private var minimizedContent: some View {
        HStack(spacing: MiniBarOverlay.dotSpacing) {
            ForEach(visibleSessions) { session in
                StatusIndicator(session: session, showWaitingSymbols: viewModel.showWaitingSymbols)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 6)
        // Native overlay: drag the bar to move it, double-click restores, and each
        // dot shows a native tooltip with its project and status.
        .overlay(
            MiniBarOverlay(
                tooltips: visibleSessions.map { "\($0.projectName) — \($0.statusTip)" },
                onDoubleClick: { viewModel.toggleMinimized() }
            )
        )
    }

    private var fullContent: some View {
        VStack(spacing: 0) {
            if visibleSessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(HudTheme.secondary)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
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

/// Header control with hover feedback, mirroring the Windows app's button highlight.
struct HeaderButton: View {
    var symbol: String?
    var text: String?
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text(text ?? "")
                        .font(.system(size: 15))
                }
            }
            .foregroundStyle(hovering ? Color.white : HudTheme.dim)
            .frame(minWidth: 16)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovering ? Color.white.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
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
                .allowsHitTesting(false)
            AgentIconView(type: session.agentType)
                .frame(width: 16, height: 16)
                .help(session.agentType.displayName)
                .allowsHitTesting(false)
            Text(session.projectName)
                .font(.system(size: 12))
                .foregroundStyle(HudTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 92, alignment: .leading)
                .allowsHitTesting(false)
            Text(session.displayTitle)
                .font(.system(size: 12))
                .foregroundStyle(HudTheme.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
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
                    .allowsHitTesting(false)
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
