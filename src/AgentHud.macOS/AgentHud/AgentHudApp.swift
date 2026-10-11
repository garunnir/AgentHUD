import SwiftUI
import AppKit

@main
struct AgentHudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AgentHudViewModel()

    init() {
        // Disable stdout buffering so logs appear immediately when redirected to a file.
        setbuf(stdout, nil)

        // Debug hook: `AgentHud --usage-selftest` prints the live usage mapping and exits
        // before any window is created. Useful if the endpoint ever changes.
                if CommandLine.arguments.contains("--usage-selftest") {
            do {
                let usage = try CodexUsageApi.shared.fetchUsageSync()
                func describe(_ window: LimitWindow?) -> String {
                    guard let window else { return "nil" }
                    return "\(Int(window.usedPercent))% used, resets \(window.resetsAt)"
                }
                print("live usage: primary=\(describe(usage.primary))")
                print("             secondary=\(describe(usage.secondary))")
                print("             plan=\(usage.planType ?? "?") limitReached=\(usage.limitReached)")
            } catch {
                print("usage fetch failed: \(error)")
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("Agent HUD", id: "hud") {
            ContentView(viewModel: viewModel)
                .frame(width: 320)
                // The window reserves title bar space even when hidden; ignore the
                // safe area so the panel fills it (no transparent strip on top).
                .ignoresSafeArea()
                .onAppear {
                    viewModel.start()
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 400)
    }
}
