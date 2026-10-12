import SwiftUI

/// Agent artwork (Claude starburst / Codex knot), scaled to fit the frame like the Windows Viewbox.
struct AgentIconView: View {
    let type: AgentType

    var body: some View {
        if type == .openCode || type == .openCodeGo {
            OpenCodeLogoView()
        } else {
            ScaledArtworkShape(path: type == .claudeCode ? AgentArtwork.claude() : AgentArtwork.codex())
                .fill(type == .claudeCode ? HudTheme.claudeFill : HudTheme.codexFill)
        }
    }
}

/// OpenCode's official mark: a white rectangular frame with a dark upper opening
/// and gray lower block. Kept as SwiftUI shapes so it stays crisp at HUD sizes.
struct OpenCodeLogoView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(red: 0x13 / 255, green: 0x10 / 255, blue: 0x10 / 255))
            Rectangle()
                .fill(.white)
                .frame(width: 9, height: 11)
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color(red: 0x13 / 255, green: 0x10 / 255, blue: 0x10 / 255))
                    .frame(width: 4.5, height: 4)
                Rectangle()
                    .fill(Color(red: 0x5A / 255, green: 0x58 / 255, blue: 0x58 / 255))
                    .frame(width: 4.5, height: 5)
            }
        }
        .frame(width: 14, height: 14)
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
