import SwiftUI
import AppKit

@main
struct AgentHudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AgentHudViewModel()

    init() {
        // Disable stdout buffering so logs appear immediately when redirected to a file.
        setbuf(stdout, nil)
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
