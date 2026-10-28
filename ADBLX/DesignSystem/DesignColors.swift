import SwiftUI

/// Adaptive color tokens backed by asset-catalog colorsets (Assets.xcassets/Colors),
/// each with Any/Dark and High Contrast variants where text or borders need them.
/// Dark values are read verbatim from the Stitch project's "Serene Shield Unified"
/// design system (assets/111a44c302cd40c9b5ccad6501fc52cf), colorMode: DARK, and
/// must not be adjusted without first updating the Stitch design system — Stitch is
/// the design authority (see Sprint 4 spec §2). Light values are Material 3 tones
/// derived from the same palettes (primary hue 272; the dark tokens are tones 80/20/30/60
/// of those palettes). The *Container fills and their on* pairs are saturated in both
/// modes, because the UI uses them as filled surfaces carrying light text.
enum DesignColors {
    static let primary = Color("primary")
    static let onPrimary = Color("onPrimary")
    static let primaryContainer = Color("primaryContainer")
    static let onPrimaryContainer = Color("onPrimaryContainer")

    static let secondary = Color("secondary")
    static let onSecondary = Color("onSecondary")
    static let secondaryContainer = Color("secondaryContainer")

    static let tertiary = Color("tertiary")
    static let onTertiary = Color("onTertiary")
    static let tertiaryContainer = Color("tertiaryContainer")

    static let error = Color("error")
    static let onError = Color("onError")
    static let errorContainer = Color("errorContainer")
    static let onErrorContainer = Color("onErrorContainer")

    static let background = Color("background")
    static let onBackground = Color("onBackground")

    static let surface = Color("surface")
    static let surfaceDim = Color("surfaceDim")
    static let surfaceBright = Color("surfaceBright")
    static let surfaceContainerLowest = Color("surfaceContainerLowest")
    static let surfaceContainerLow = Color("surfaceContainerLow")
    static let surfaceContainer = Color("surfaceContainer")
    static let surfaceContainerHigh = Color("surfaceContainerHigh")
    static let surfaceContainerHighest = Color("surfaceContainerHighest")
    static let onSurface = Color("onSurface")
    static let onSurfaceVariant = Color("onSurfaceVariant")

    static let outline = Color("outline")
    static let outlineVariant = Color("outlineVariant")

    static let shadow = Color("shadow")
}
