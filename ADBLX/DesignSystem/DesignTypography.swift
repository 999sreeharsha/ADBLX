import SwiftUI

/// Typography tokens read verbatim from the Stitch project's "Serene Shield" theme.
/// Font families fall back to system fonts until the actual font files are bundled
/// (tracked separately) — sizes and weights are exact regardless.
enum DesignTypography {
    static let headlineLargeSize: CGFloat = 34
    static let headlineLargeWeight: Font.Weight = .bold
    static let headlineLarge = Font.custom("PlusJakartaSans-Bold", size: headlineLargeSize)

    static let headlineMediumSize: CGFloat = 22
    static let headlineMediumWeight: Font.Weight = .semibold
    static let headlineMedium = Font.custom("PlusJakartaSans-SemiBold", size: headlineMediumSize)

    static let bodyLargeSize: CGFloat = 17
    static let bodyLargeWeight: Font.Weight = .regular
    static let bodyLarge = Font.custom("Inter-Regular", size: bodyLargeSize)

    static let bodySmallSize: CGFloat = 15
    static let bodySmallWeight: Font.Weight = .regular
    static let bodySmall = Font.custom("Inter-Regular", size: bodySmallSize)

    static let labelCapsSize: CGFloat = 12
    static let labelCapsWeight: Font.Weight = .semibold
    static let labelCaps = Font.custom("Geist-SemiBold", size: labelCapsSize)

    static let labelMonoSize: CGFloat = 13
    static let labelMonoWeight: Font.Weight = .medium
    static let labelMono = Font.custom("Geist-Medium", size: labelMonoSize)
}
