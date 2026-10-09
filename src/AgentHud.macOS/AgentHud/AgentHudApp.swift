import SwiftUI

@main
struct AgentHudApp: App {
    @StateObject private var viewModel = AgentHudViewModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(viewModel: viewModel)
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
        }
        .menuBarExtraStyle(.window)
    }
}
