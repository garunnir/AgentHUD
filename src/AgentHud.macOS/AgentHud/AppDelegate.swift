import AppKit

/// Configures the HUD window to float above everything, appear on every Space,
/// hide the traffic-light buttons, and remember its position across launches.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let originKey = "hud.window.origin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // HUD lives in the menu-bar/accessory space: no Dock icon, no app menu.
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in self?.configureMainWindow() }
    }

    private func configureMainWindow(attempt: Int = 0) {
        guard let window = NSApp.windows.first else {
            // SwiftUI may create the window slightly after launch; retry briefly.
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.configureMainWindow(attempt: attempt + 1)
                }
            }
            return
        }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.remove(.resizable)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }

        restoreOrigin(of: window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.saveOrigin(of: window)
        }
    }

    private func saveOrigin(of window: NSWindow) {
        let origin = window.frame.origin
        UserDefaults.standard.set([origin.x, origin.y], forKey: originKey)
    }

    private func restoreOrigin(of window: NSWindow) {
        guard let saved = UserDefaults.standard.array(forKey: originKey) as? [Double],
              saved.count == 2 else { return }
        let origin = NSPoint(x: saved[0], y: saved[1])
        // Only restore when the saved position is still on a connected screen.
        let onScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.insetBy(dx: -40, dy: -40).contains(origin)
        }
        guard onScreen else { return }
        window.setFrameOrigin(origin)
    }
}
