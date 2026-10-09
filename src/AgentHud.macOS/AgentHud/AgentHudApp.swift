import SwiftUI
import AppKit

@main
struct AgentHudApp: App {
    @StateObject private var viewModel = AgentHudViewModel()

    init() {
        // Disable stdout buffering so logs appear immediately when redirected to a file.
        setbuf(stdout, nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(width: 320, height: 400)
                .onAppear {
                    viewModel.start()
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 320, height: 400)
    }
}
