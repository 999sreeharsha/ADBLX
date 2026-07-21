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

/// Color tokens read verbatim from the Stitch project's "Serene Shield Unified"
/// design system (assets/111a44c302cd40c9b5ccad6501fc52cf), colorMode: DARK —
/// the corrected, single source of truth after the original "Serene Shield"
/// theme (light mode) was found to not match any of the actual rendered
/// screens. Do not adjust these values without first updating the Stitch
/// design system — Stitch is the design authority (see Sprint 4 spec §2).
enum DesignColors {
    static let primary = Color(hex: "#b4c5ff")
    static let onPrimary = Color(hex: "#002a78")
    static let primaryContainer = Color(hex: "#2563eb")
    static let onPrimaryContainer = Color(hex: "#eeefff")

    static let secondary = Color(hex: "#53e16f")
    static let onSecondary = Color(hex: "#003911")
    static let secondaryContainer = Color(hex: "#05b046")

    static let tertiary = Color(hex: "#ddb7ff")
    static let onTertiary = Color(hex: "#490080")
    static let tertiaryContainer = Color(hex: "#943fe2")

    static let error = Color(hex: "#ffb4ab")
    static let onError = Color(hex: "#690005")
    static let errorContainer = Color(hex: "#93000a")
    static let onErrorContainer = Color(hex: "#ffdad6")

    static let background = Color(hex: "#111317")
    static let onBackground = Color(hex: "#e2e2e7")

    static let surface = Color(hex: "#111317")
    static let surfaceDim = Color(hex: "#111317")
    static let surfaceBright = Color(hex: "#37393d")
    static let surfaceContainerLowest = Color(hex: "#0c0e12")
    static let surfaceContainerLow = Color(hex: "#1a1c1f")
    static let surfaceContainer = Color(hex: "#1e2023")
    static let surfaceContainerHigh = Color(hex: "#282a2e")
    static let surfaceContainerHighest = Color(hex: "#333539")
    static let onSurface = Color(hex: "#e2e2e7")
    static let onSurfaceVariant = Color(hex: "#c3c6d7")

    static let outline = Color(hex: "#8d90a0")
    static let outlineVariant = Color(hex: "#434655")
}
