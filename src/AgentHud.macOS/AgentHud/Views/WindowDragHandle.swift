import SwiftUI
import AppKit

/// A dedicated drag handle for header-like areas. Single-press drag moves the window
/// (NSWindow.performDrag), double-click runs the provided action (e.g. toggle minimize).
/// Interactive controls drawn above the handle (buttons) keep their own clicks because
/// their gesture recognizers take precedence.
final class DragHandleView: NSView {
    var onDoubleClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let handler = onDoubleClick {
            handler()
        } else {
            window?.performDrag(with: event)
        }
    }
}

struct WindowDragHandle: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DragHandleView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DragHandleView)?.onDoubleClick = onDoubleClick
    }
}
