import SwiftUI

/// Typography tokens read verbatim from the Stitch project's "Serene Shield Unified"
/// design system (assets/111a44c302cd40c9b5ccad6501fc52cf). Font families fall back
/// to system fonts until the actual font files are bundled (tracked separately) —
/// sizes and weights are exact regardless.
enum DesignTypography {
    static let headlineLargeSize: CGFloat = 32
    static let headlineLargeWeight: Font.Weight = .bold
    static let headlineLarge = Font.custom("Manrope-Bold", size: headlineLargeSize)

    static let headlineMediumSize: CGFloat = 20
    static let headlineMediumWeight: Font.Weight = .semibold
    static let headlineMedium = Font.custom("Manrope-SemiBold", size: headlineMediumSize)

    static let bodyLargeSize: CGFloat = 17
    static let bodyLargeWeight: Font.Weight = .regular
    static let bodyLarge = Font.custom("Inter-Regular", size: bodyLargeSize)

    static let bodySmallSize: CGFloat = 15
    static let bodySmallWeight: Font.Weight = .regular
    static let bodySmall = Font.custom("Inter-Regular", size: bodySmallSize)

    static let labelCapsSize: CGFloat = 11
    static let labelCapsWeight: Font.Weight = .semibold
    static let labelCaps = Font.custom("Inter-SemiBold", size: labelCapsSize)

    static let labelMonoSize: CGFloat = 13
    static let labelMonoWeight: Font.Weight = .medium
    static let labelMono = Font.custom("Inter-Medium", size: labelMonoSize)
}
