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

        // Debug hook: `AgentHud --render=mini|full` writes a preview PNG and exits,
        // again before any window exists, so layout can be reviewed headlessly.
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--render=") }) {
            exportPreview(mode: String(argument.dropFirst("--render=".count)))
        }
    }

    /// Renders the HUD (sample data, no window) next to the source for review.
    private func exportPreview(mode: String) {
        guard mode == "mini" || mode == "full" else {
            print("usage: --render=mini|full")
            exit(0)
        }
        let preview = AgentHudViewModel()
        preview.installPreviewSessions()
        preview.isPreviewMode = true
        preview.isMinimized = mode != "full"
        let renderer = ImageRenderer(content: ContentView(viewModel: preview))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("render failed")
            exit(1)
        }
        let path = "/tmp/agenthud-preview-\(mode).png"
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("rendered \(path) \(Int(image.size.width))x\(Int(image.size.height))pt")
        } catch {
            print("render write failed: \(error)")
        }
        exit(0)
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
        .defaultSize(width: 320, height: 180)
    }
}
