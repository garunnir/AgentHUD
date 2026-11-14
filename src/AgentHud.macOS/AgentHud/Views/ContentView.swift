import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

public struct ContentView: View {
    @ObservedObject var viewModel: AgentHudViewModel
    @State private var showSettings = false
    @State private var showMemo = false

    public init(viewModel: AgentHudViewModel) {
        self.viewModel = viewModel
    }

    private var visibleSessions: [AgentSession] {
        viewModel.sessions.filter { !viewModel.hiddenSessionIds.contains($0.id) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Minimized mode drops the whole header: it becomes a pill of dots, so the
            // only way back is a double-click on the bar.
            if viewModel.isMinimized {
                minimizedContent
            } else {
                header
                fullContent
            }
        }
        .padding(viewModel.isMinimized
                 ? EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
                 : EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
        // Height follows the content: only the rows that are actually shown reserve
        // space, so the panel has no empty strip at the bottom.
        .frame(maxWidth: viewModel.isMinimized ? nil : .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .fill(HudTheme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .stroke(HudTheme.border, lineWidth: 1)
        )
        // Minimized mode sizes to the dots row; full mode keeps the fixed panel width.
        .frame(width: viewModel.isMinimized ? nil : 320)
        .background(
            Group {
                if viewModel.isPreviewMode {
                    Color.clear
                } else {
                    WindowConfigurator(minimized: viewModel.isMinimized)
                }
            }
        )
    }

    /// The dots bar is 22pt tall, so half of that makes it a pill.
    private var panelCornerRadius: CGFloat { viewModel.isMinimized ? 11 : 14 }

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
            HeaderButton(symbol: "note.text", help: Localiz.current.string("Main.Memo")) {
                showMemo.toggle()
            }
            .popover(isPresented: $showMemo, arrowEdge: .bottom) {
                MemoEditor(header: Localiz.current.string("Main.Memo"), initialText: viewModel.globalMemo) {
                    viewModel.setGlobalMemo($0)
                }
            }
            HeaderButton(symbol: "gearshape", help: Localiz.current.string("Main.Settings")) {
                showSettings.toggle()
            }
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsPopover(viewModel: viewModel)
            }
            HeaderButton(symbol: "minus", help: Localiz.current.string("Main.Minimize")) {
                viewModel.toggleMinimized()
            }
            HeaderButton(text: "×", help: Localiz.current.string("Common.Close")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.bottom, 8)
        // Drag the window from anywhere on the header; double-click toggles minimized.
        .background(
            Group {
                if viewModel.isPreviewMode {
                    Color.clear
                } else {
                    WindowDragHandle { viewModel.toggleMinimized() }
                }
            }
        )
    }

    private var minimizedContent: some View {
        HStack(spacing: MiniBarOverlay.dotSpacing) {
            if visibleSessions.isEmpty {
                // Keep a usable restore target when the last tracked session ends.
                // This is intentionally hollow/dim: it does not pretend an agent is
                // active, but prevents the minimized HUD from collapsing to a tiny
                // unclickable sliver.
                Circle()
                    .stroke(HudTheme.dim.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                    .help("No active sessions — double-click to restore")
                    .allowsHitTesting(false)
            } else {
                ForEach(visibleSessions) { session in
                    StatusIndicator(session: session, showWaitingSymbols: viewModel.showWaitingSymbols)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: visibleSessions.isEmpty ? 20 : 6, minHeight: 18)
        // Native overlay: drag the bar to move it, double-click restores, and each
        // dot shows a native tooltip with its project and status.
        .overlay(
            Group {
                if viewModel.isPreviewMode {
                    Color.clear
                } else {
                    MiniBarOverlay(
                        tooltips: visibleSessions.isEmpty
                            ? ["No active sessions — double-click to restore"]
                            : visibleSessions.map { "\($0.projectName) — \($0.statusTip)" },
                        onDoubleClick: { viewModel.toggleMinimized() }
                    )
                }
            }
        )
    }

    private var fullContent: some View {
        VStack(spacing: 0) {
            if viewModel.isScanning && visibleSessions.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning sessions…")
                        .font(.system(size: 12))
                        .foregroundStyle(HudTheme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if visibleSessions.isEmpty {
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
        if !rows.isEmpty || viewModel.isLoadingOpenCodeGoUsage {
            Divider()
                .overlay(Color.white.opacity(0.1))
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 0) {
                if !rows.isEmpty {
                    let blocks = groups(of: rows)
                    ForEach(Array(blocks.indices), id: \.self) { index in
                        if index > 0 { Color.clear.frame(height: 10) }
                        VStack(spacing: 5) {
                            ForEach(blocks[index]) { row in
                                UsageGaugeView(row: row, timeColumnWidth: timeColumnWidth(rows))
                            }
                        }
                    }
                }
                if viewModel.isLoadingOpenCodeGoUsage {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(Localiz.current.string("Usage.Loading"))
                            .font(.system(size: 11))
                            .foregroundStyle(HudTheme.secondary)
                    }
                    .padding(.top, rows.isEmpty ? 0 : 7)
                }
            }
        }
    }

    /// Rows stay in one block per agent, with a wider gap between agents.
    private func groups(of rows: [UsageRow]) -> [[UsageRow]] {
        var result: [[UsageRow]] = []
        for row in rows {
            if let last = result.indices.last, result[last].first?.agent == row.agent {
                result[last].append(row)
            } else {
                result.append([row])
            }
        }
        return result
    }

    /// Widest right-hand string across the rows, so every bar ends at the same x
    /// instead of shifting as the reset text changes length.
    private func timeColumnWidth(_ rows: [UsageRow]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11)
        var width: CGFloat = 0
        for row in rows {
            let measured = (row.displayText as NSString).size(withAttributes: [.font: font]).width
            width = max(width, measured)
        }
        return width.rounded(.up) + 2
    }
}

/// Header control with hover feedback, mirroring the Windows app's button highlight.
struct HeaderButton: View {
    var symbol: String?
    var text: String?
    let help: String
    let action: () -> Void

    @State private var hovering = false

    /// All three controls share one hit target: a bare "×" is much narrower than a
    /// symbol, which would otherwise leave it hard to click.
    static let hitSize = CGSize(width: 22, height: 18)

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
            .frame(width: Self.hitSize.width, height: Self.hitSize.height)
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
    @State private var showOpenCodeLogin = false
    @State private var discordURL = ""

    private let windowChoices = [5, 10, 30, 60, 120, 240, 1440]
    /// Doubles, not Ints: the picker's tags must match the Double binding, otherwise
    /// SwiftUI cannot show or write the selection.
    private let warningChoices = stride(from: 0, through: 90, by: 5).map(Double.init)

    var body: some View {
        // Scrolls: the ported Windows options make the list taller than a small screen.
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(Localiz.current.string("Main.Settings"))
                    .font(.headline)
                Picker(Localiz.current.string("Settings.Language"), selection: $viewModel.uiLanguage) {
                    ForEach(Localiz.current.languageChoices, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .frame(width: 220)
                Picker(Localiz.current.string("Settings.ActiveWindow"), selection: $viewModel.activeWindowMinutes) {
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
                Picker(Localiz.current.string("Settings.ConversationTarget"),
                       selection: $viewModel.conversationTarget) {
                    ForEach(ConversationTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .frame(width: 220)
                VStack(alignment: .leading, spacing: 4) {
                    Picker(selection: $viewModel.warningPercent) {
                        ForEach(warningChoices, id: \.self) { percent in
                            Text(percent == 0
                                 ? Localiz.current.string("Settings.WarningOff")
                                 : "\(Int(percent))%")
                                .tag(percent)
                        }
                    } label: {
                        Text(Localiz.current.string("Settings.WarningLine"))
                            .font(.system(size: 12))
                    }
                    .frame(width: 220)
                    Text(Localiz.current.string("Settings.WarningHint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                soundSetting(Localiz.current.string("Settings.CompleteSound"), enabled: $viewModel.completeSoundEnabled,
                             sound: $viewModel.completeSound, file: $viewModel.completeSoundFile, ask: false)
                soundSetting(Localiz.current.string("Settings.AskSound"), enabled: $viewModel.askSoundEnabled,
                             sound: $viewModel.askSound, file: $viewModel.askSoundFile, ask: true)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $viewModel.notifyLimitReset) {
                        Text(Localiz.current.string("Settings.NotifyLimitReset")).font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    Toggle(isOn: $viewModel.notifyVisibleOnly) {
                        Text(Localiz.current.string("Settings.NotifyVisibleOnly")).font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, 16)
                    .disabled(!viewModel.notifyLimitReset)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $viewModel.discordEnabled) {
                        Text(Localiz.current.string("Settings.DiscordEnable")).font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    Group {
                        Toggle(isOn: $viewModel.discordNotifyAsk) {
                            Text(Localiz.current.string("Settings.DiscordAsk")).font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                        Toggle(isOn: $viewModel.discordNotifyComplete) {
                            Text(Localiz.current.string("Settings.DiscordComplete")).font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                        HStack(spacing: 6) {
                            SecureField(Localiz.current.string("Settings.DiscordWebhook"), text: $discordURL)
                                .textFieldStyle(.roundedBorder)
                            Button(Localiz.current.string("Settings.Save")) {
                                viewModel.setDiscordWebhook(discordURL)
                                let trimmed = discordURL.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty || DiscordNotifier.isValidWebhookURL(trimmed) { discordURL = "" }
                            }
                            Button(Localiz.current.string("Settings.DiscordTest")) { viewModel.testDiscord() }
                        }
                        if !viewModel.discordStatus.isEmpty {
                            Text(viewModel.discordStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(Localiz.current.string("Settings.DiscordHint"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 16)
                    .disabled(!viewModel.discordEnabled)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $viewModel.autoResume) {
                        Text(Localiz.current.string("Settings.AutoResume")).font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    TextField(AutoResumer.defaultPrompt, text: $viewModel.resumePrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .lineLimit(2...4)
                        .disabled(!viewModel.autoResume)
                        .help(Localiz.current.string("Settings.ResumePromptTip"))
                    Text(Localiz.current.string("Settings.AutoResumeHint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $viewModel.claudeLimitLinked) {
                        Text(Localiz.current.string("Settings.ClaudeLink")).font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    Text(Localiz.current.string("Settings.ClaudeLinkHint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(Localiz.current.string("Settings.Budget"))
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    budgetField(Localiz.current.string("Settings.Budget5h"), value: $viewModel.claudeBudget5h)
                    budgetField(Localiz.current.string("Settings.BudgetWeek"), value: $viewModel.claudeBudgetWeek)
                    Text(Localiz.current.string("Settings.BudgetHint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenCode Go")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("Workspace ID (wrk_…)", text: $viewModel.openCodeWorkspaceID)
                        .textFieldStyle(.roundedBorder)
                    Text("Paste the workspace ID from your OpenCode Console URL.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Button(OpenCodeGoUsageApi.shared.hasCookies ? "Re-login" : "Login") {
                            showOpenCodeLogin = true
                        }
                        Button("Refresh") {
                            viewModel.refreshOpenCodeGoUsage()
                        }
                        .disabled(viewModel.openCodeWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if OpenCodeGoUsageApi.shared.hasCookies {
                            Button("Log out") {
                                OpenCodeGoUsageApi.shared.clearCookies()
                                viewModel.clearOpenCodeGoUsage()
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $viewModel.showPaceMarker) {
                        Text(Localiz.current.string("Settings.PaceLine"))
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    Text(Localiz.current.string("Settings.PaceLineHint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        }
        .frame(width: 280, height: 560)
        .sheet(isPresented: $showOpenCodeLogin) {
            OpenCodeLoginView(viewModel: viewModel)
        }
    }

    /// Checkbox + sound choice (system sound or a file) + preview, like the Windows settings.
    private func soundSetting(_ title: String, enabled: Binding<Bool>, sound: Binding<String>,
                              file: Binding<String>, ask: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: enabled) {
                Text(title).font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 4) {
                Picker("", selection: sound) {
                    ForEach(SoundPlayer.systemSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    Text(Localiz.current.string("Sound.File")).tag(SoundPlayer.fileKey)
                }
                .labelsHidden()
                .frame(width: 150)
                Button(Localiz.current.string("Settings.File")) {
                    if let path = pickSoundFile() {
                        file.wrappedValue = path
                        sound.wrappedValue = SoundPlayer.fileKey
                    }
                }
                .help(file.wrappedValue)
                Button("▶") { viewModel.previewSound(ask: ask) }
                    .help(Localiz.current.string("Settings.Preview"))
            }
            .disabled(!enabled.wrappedValue)
        }
    }

    private func pickSoundFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = Localiz.current.string("Sound.PickTitle")
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func budgetField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
        }
    }
}

/// Notepad popover (global or per project). Saves when it closes, like the Windows memo window.
struct MemoEditor: View {
    let header: String
    let initialText: String
    let save: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header)
                .font(.system(size: 12, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(width: 280, height: 200)
        }
        .padding(10)
        .onAppear { text = initialText }
        .onDisappear { save(text) }
    }
}

/// Separate Console login session. Chrome's HttpOnly cookie cannot be read by a
/// native app, so the user signs in once in this small in-app web view instead.
final class OpenCodeWebSession: ObservableObject {
    var webView: WKWebView?

    func readCookies(_ completion: @escaping ([HTTPCookie]) -> Void) {
        webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies(completion)
    }
}

struct OpenCodeLoginView: View {
    @ObservedObject var viewModel: AgentHudViewModel
    @StateObject private var session = OpenCodeWebSession()
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to OpenCode Console")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(12)
            OpenCodeWebView(session: session)
            HStack {
                Text(error ?? "After signing in, click Done to save this session securely.")
                    .font(.system(size: 11))
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                Spacer()
                Button("Done") {
                    session.readCookies { cookies in
                        do {
                            try OpenCodeGoUsageApi.shared.saveCookies(cookies)
                            DispatchQueue.main.async {
                                viewModel.openCodeGoCookiesSaved()
                                dismiss()
                            }
                        } catch {
                            DispatchQueue.main.async { self.error = "OpenCode Console login was not detected." }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 760, height: 620)
    }
}

struct OpenCodeWebView: NSViewRepresentable {
    @ObservedObject var session: OpenCodeWebSession

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        session.webView = webView
        webView.load(URLRequest(url: URL(string: "https://opencode.ai/console")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        session.webView = nsView
    }
}

struct SessionRow: View {
    let session: AgentSession
    @ObservedObject var viewModel: AgentHudViewModel
    @State private var hovering = false
    @State private var showMemo = false

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
            if viewModel.hasProjectMemo(session.projectPath) {
                Button(action: { showMemo = true }) {
                    Image(systemName: "note.text")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(HudTheme.dim)
                .help(viewModel.projectMemo(session.projectPath))
            }
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
            if session.projectPath != nil {
                Button(Localiz.current.string("Main.ProjectMemo")) { showMemo = true }
            }
        }
        .popover(isPresented: $showMemo, arrowEdge: .leading) {
            MemoEditor(header: HudTheme.formatPattern(Localiz.current.string("Memo.ProjectHeader"), [session.projectName]),
                       initialText: viewModel.projectMemo(session.projectPath)) { text in
                if let path = session.projectPath { viewModel.setProjectMemo(path, text) }
            }
        }
    }
}
