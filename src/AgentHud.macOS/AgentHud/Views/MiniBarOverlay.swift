import SwiftUI
import AppKit

/// Transparent overlay for the minimized bar. It handles window dragging and shows a
/// native tooltip per dot (project and status), which SwiftUI's .help does not provide
/// reliably in this window setup.
struct MiniBarOverlay: NSViewRepresentable {
    /// Tooltip per dot, in the same order as the dots.
    let tooltips: [String]
    let onDoubleClick: () -> Void

    /// Must match the dot layout in StatusIndicator + HStack(spacing: 4).
    static let dotWidth: CGFloat = 12
    static let dotSpacing: CGFloat = 4

    func makeNSView(context: Context) -> NSView {
        let view = MiniBarMouseView()
        view.tooltips = tooltips
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MiniBarMouseView else { return }
        view.tooltips = tooltips
        view.onDoubleClick = onDoubleClick
    }
}

final class MiniBarMouseView: NSView {
    var tooltips: [String] = [] {
        didSet { refreshToolTips() }
    }
    var onDoubleClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func layout() {
        super.layout()
        refreshToolTips()
    }

    private func refreshToolTips() {
        removeAllToolTips()
        let pitch = MiniBarOverlay.dotWidth + MiniBarOverlay.dotSpacing
        for index in tooltips.indices {
            let rect = NSRect(x: CGFloat(index) * pitch, y: 0, width: pitch, height: bounds.height)
            addToolTip(rect, owner: self, userData: nil)
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let pitch = MiniBarOverlay.dotWidth + MiniBarOverlay.dotSpacing
        let index = Int(point.x / pitch)
        guard index >= 0 && index < tooltips.count else { return "" }
        return tooltips[index]
    }
}
