import SwiftUI
import AppKit

@main
struct AgentHudApp: App {
    @StateObject private var viewModel = AgentHudViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(width: 320, height: 400)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 320, height: 400)
    }
}
