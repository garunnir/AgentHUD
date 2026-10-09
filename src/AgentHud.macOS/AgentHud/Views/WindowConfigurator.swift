import SwiftUI
import AppKit

/// Background view that drags the window when the user drags anywhere that is not
/// an interactive control. SwiftUI content (a hosting view) can swallow mouse events,
/// which makes NSWindow.isMovableByWindowBackground unreliable, so we drag explicitly
/// via NSWindow.performDrag.
final class DraggableWindowBackgroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Attaches to the HUD content view and configures the exact NSWindow that hosts it:
/// floating level, all-Spaces visibility, hidden title bar chrome, drag-anywhere,
/// and saved/restored position. Using the view's own window avoids targeting the
/// wrong window (e.g. a popover) the way NSApp.windows.first can.
struct WindowConfigurator: NSViewRepresentable {
    private static let originKey = "hud.window.origin"

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var window: NSWindow?
        var didRestoreOrigin = false
        var didLogDiagnostics = false
        var moveObserver: NSObjectProtocol?
    }

    func makeNSView(context: Context) -> NSView {
        let view = DraggableWindowBackgroundView()
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window, coordinator: context.coordinator) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let observer = coordinator.moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        if coordinator.window !== window {
            coordinator.window = window
            coordinator.didRestoreOrigin = false
        }

        if !coordinator.didLogDiagnostics {
            coordinator.didLogDiagnostics = true
            let mask = window.styleMask
            print("Window diagnostics: frame=\(window.frame) contentLayoutRect=\(window.contentLayoutRect) " +
                  "styleMask=\(mask) fullSizeContentView=\(mask.contains(.fullSizeContentView)) " +
                  "hostingSafeArea=\(String(describing: window.contentView?.safeAreaInsets))")
        }

        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Let the content extend under the (transparent) title bar area.
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.resizable)
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }

        if !coordinator.didRestoreOrigin {
            coordinator.didRestoreOrigin = true
            restoreOrigin(of: window)
        }
        if coordinator.moveObserver == nil {
            coordinator.moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                let origin = window.frame.origin
                UserDefaults.standard.set([origin.x, origin.y], forKey: Self.originKey)
            }
        }
    }

    private func restoreOrigin(of window: NSWindow) {
        guard let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double],
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
