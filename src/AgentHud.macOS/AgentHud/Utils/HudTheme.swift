import SwiftUI

/// Colors and formatting shared by the HUD, mirroring the Windows app's palette.
enum HudTheme {
    // Frame
    static let background = Color(red: 0x14 / 255, green: 0x17 / 255, blue: 0x1D / 255).opacity(0.93)
    static let border = Color.white.opacity(0.23)
    static let barTrack = Color.white.opacity(0.16)

    // Text
    static let title = Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xED / 255)
    static let secondary = Color(red: 0xAE / 255, green: 0xB8 / 255, blue: 0xC6 / 255)
    static let dim = Color(red: 0x91 / 255, green: 0xA0 / 255, blue: 0xB5 / 255)

    // Agent artwork
    static let claudeFill = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let codexFill = Color.white

    static func stateColor(_ state: AgentState) -> Color {
        switch state {
        case .working, .thinking, .starting:
            return Color(red: 0, green: 0xBF / 255, blue: 1)                    // DeepSkyBlue
        case .waitingForInput, .waitingForApproval:
            return Color(red: 1, green: 0xD7 / 255, blue: 0)                    // Gold
        case .error:
            return Color(red: 1, green: 0x45 / 255, blue: 0)                    // OrangeRed
        case .rateLimited:
            return Color(red: 1, green: 0x69 / 255, blue: 0xB4 / 255)           // HotPink
        case .completed:
            return Color(red: 0x32 / 255, green: 0xCD / 255, blue: 0x32 / 255)  // LimeGreen
        case .idle, .stopped:
            return Color(red: 0x70 / 255, green: 0x80 / 255, blue: 0x90 / 255)  // SlateGray
        default:
            return Color(red: 0x93 / 255, green: 0x70 / 255, blue: 0xDB / 255)  // MediumPurple
        }
    }

    static func usageFill(usedPercent: Double) -> Color {
        if usedPercent >= 90 { return Color(red: 0xCD / 255, green: 0x5C / 255, blue: 0x5C / 255) }   // IndianRed
        if usedPercent >= 70 { return Color(red: 0xDA / 255, green: 0xA5 / 255, blue: 0x20 / 255) }   // Goldenrod
        return Color(red: 0x46 / 255, green: 0x82 / 255, blue: 0xB4 / 255)                            // SteelBlue
    }

    /// 1234567 → "1.2M", 34567 → "34.6K", 123 → "123" (same as the Windows FormatTokens).
    static func formatTokens(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Replaces .NET-style placeholders ({0}, {1}, {0:0.#}) in a localized string.
    static func formatPattern(_ pattern: String, _ args: [Any]) -> String {
        var result = pattern
        for (index, arg) in args.enumerated() {
            let value: String
            if let number = arg as? Double {
                let formatted = String(format: "%.1f", number)
                value = formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
            } else {
                value = "\(arg)"
            }
            result = result.replacingOccurrences(of: "{\(index):0.#}", with: value)
            result = result.replacingOccurrences(of: "{\(index)}", with: value)
        }
        return result
    }
}
