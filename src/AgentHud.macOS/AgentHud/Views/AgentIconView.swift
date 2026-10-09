import SwiftUI

/// Agent artwork (Claude starburst / Codex knot), scaled to fit the frame like the Windows Viewbox.
struct AgentIconView: View {
    let type: AgentType

    var body: some View {
        ScaledArtworkShape(path: type == .claudeCode ? AgentArtwork.claude() : AgentArtwork.codex())
            .fill(type == .claudeCode ? HudTheme.claudeFill : HudTheme.codexFill)
    }
}

struct ScaledArtworkShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let bounds = path.boundingRect
        guard bounds.width > 0, bounds.height > 0 else { return path }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let tx = rect.minX + (rect.width - bounds.width * scale) / 2
        let ty = rect.minY + (rect.height - bounds.height * scale) / 2
        let transform = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        return path.applying(transform)
    }
}
