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
/// borderless floating window on all Spaces, drag-anywhere support, and saved position.
/// Also keeps the window's top and right edges stable when the content resizes
/// (e.g. minimizing to the dots bar), matching the Windows behavior.
struct WindowConfigurator: NSViewRepresentable {
    let minimized: Bool

    private static let originKey = "hud.window.origin"

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var window: NSWindow?
        var didRestoreOrigin = false
        var didLogDiagnostics = false
        var moveObserver: NSObjectProtocol?
        var resizeObserver: NSObjectProtocol?
        var rightEdge: CGFloat?
        var topEdge: CGFloat?
        var lastSize: NSSize?
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
        if let observer = coordinator.resizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        if coordinator.window !== window {
            coordinator.window = window
            coordinator.didRestoreOrigin = false
            coordinator.rightEdge = window.frame.maxX
            coordinator.topEdge = window.frame.maxY
            coordinator.lastSize = window.frame.size
        }

        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Drop the title bar entirely: a hidden title bar still reserves ~28pt,
        // which otherwise shows as a transparent strip or extra padding.
        window.styleMask.remove(.titled)
        window.styleMask.remove(.resizable)
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }

        if !coordinator.didLogDiagnostics {
            coordinator.didLogDiagnostics = true
            let mask = window.styleMask
            print("Window diagnostics: frame=\(window.frame) contentLayoutRect=\(window.contentLayoutRect) " +
                  "styleMask=\(mask) titled=\(mask.contains(.titled)) " +
                  "safeArea=\(String(describing: window.contentView?.safeAreaInsets))")
        }

        if !coordinator.didRestoreOrigin {
            coordinator.didRestoreOrigin = true
            restoreOrigin(of: window)
        }
        // The window has to be exactly as tall as what it shows. SwiftUI keeps a
        // window that was ever resized, so pin the height to the content's ideal size
        // whenever the rows change (a session ending, a minimized bar, ...).
        if let ideal = window.contentView?.fittingSize,
           ideal.height > 20,
           abs(window.contentLayoutRect.height - ideal.height) > 0.5 {
            window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: ideal.height))
        }
        if coordinator.moveObserver == nil {
            coordinator.moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak window, weak coordinator] _ in
                guard let window, let coordinator else { return }
                // A move caused by a resize must not refresh the anchor edges,
                // otherwise the resize anchor is immediately lost.
                let size = window.frame.size
                let sizeChanged = coordinator.lastSize != nil && coordinator.lastSize != size
                coordinator.lastSize = size
                if !sizeChanged {
                    coordinator.rightEdge = window.frame.maxX
                    coordinator.topEdge = window.frame.maxY
                }
                let origin = window.frame.origin
                UserDefaults.standard.set([origin.x, origin.y], forKey: Self.originKey)
            }
        }
        if coordinator.resizeObserver == nil {
            coordinator.resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak window, weak coordinator] _ in
                guard let window, let coordinator else { return }
                coordinator.lastSize = window.frame.size
                guard let right = coordinator.rightEdge, let top = coordinator.topEdge else { return }
                let target = NSPoint(x: right - window.frame.width, y: top - window.frame.height)
                if abs(window.frame.origin.x - target.x) > 0.5 || abs(window.frame.origin.y - target.y) > 0.5 {
                    window.setFrameOrigin(target)
                }
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
