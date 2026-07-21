import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Color tokens read verbatim from the Stitch project's "Serene Shield" theme
/// (projects/16038318836427840964). Do not adjust these values without first
/// updating the Stitch theme — Stitch is the design authority (see Sprint 4 spec §2).
enum DesignColors {
    static let primary = Color(hex: "#3f3bbd")
    static let primaryContainer = Color(hex: "#5856d6")
    static let onPrimary = Color(hex: "#ffffff")
    static let onPrimaryContainer = Color(hex: "#e7e4ff")

    static let secondary = Color(hex: "#0058bc")
    static let secondaryContainer = Color(hex: "#0070eb")
    static let onSecondary = Color(hex: "#ffffff")

    static let tertiary = Color(hex: "#7e3e00")
    static let tertiaryContainer = Color(hex: "#a25100")
    static let onTertiary = Color(hex: "#ffffff")

    static let error = Color(hex: "#ba1a1a")
    static let errorContainer = Color(hex: "#ffdad6")
    static let onError = Color(hex: "#ffffff")
    static let onErrorContainer = Color(hex: "#93000a")

    static let background = Color(hex: "#fcf8fb")
    static let onBackground = Color(hex: "#1b1b1d")

    static let surface = Color(hex: "#fcf8fb")
    static let surfaceDim = Color(hex: "#dcd9dc")
    static let surfaceBright = Color(hex: "#fcf8fb")
    static let surfaceContainerLowest = Color(hex: "#ffffff")
    static let surfaceContainerLow = Color(hex: "#f6f3f5")
    static let surfaceContainer = Color(hex: "#f0edef")
    static let surfaceContainerHigh = Color(hex: "#eae7ea")
    static let surfaceContainerHighest = Color(hex: "#e4e2e4")
    static let onSurface = Color(hex: "#1b1b1d")
    static let onSurfaceVariant = Color(hex: "#464554")

    static let outline = Color(hex: "#777585")
    static let outlineVariant = Color(hex: "#c7c4d6")
}
