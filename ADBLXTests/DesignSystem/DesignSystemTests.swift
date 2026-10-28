// ADBLXTests/DesignSystem/DesignSystemTests.swift
import Testing
import SwiftUI
@testable import ADBLX

@Suite("DesignColors")
struct DesignColorsTests {
    private func resolved(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return color.resolve(in: environment)
    }

    private func hex(_ color: Color, _ scheme: ColorScheme) -> String {
        let value = resolved(color, scheme)
        func byte(_ component: Float) -> Int { Int((component * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(value.red), byte(value.green), byte(value.blue))
    }

    private func luminance(_ color: Color, _ scheme: ColorScheme) -> Double {
        let value = resolved(color, scheme)
        func linear(_ component: Float) -> Double {
            let c = Double(component)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
    }

    private func contrast(_ a: Color, _ b: Color, _ scheme: ColorScheme) -> Double {
        let (hi, lo) = (max(luminance(a, scheme), luminance(b, scheme)), min(luminance(a, scheme), luminance(b, scheme)))
        return (hi + 0.05) / (lo + 0.05)
    }

    @Test("dark values match the Serene Shield Unified theme")
    func darkMatchesTheme() {
        #expect(hex(DesignColors.primary, .dark) == "#b4c5ff")
        #expect(hex(DesignColors.secondary, .dark) == "#53e16f")
        #expect(hex(DesignColors.background, .dark) == "#111317")
        #expect(hex(DesignColors.onSurface, .dark) == "#e2e2e7")
        #expect(hex(DesignColors.outlineVariant, .dark) == "#434655")
    }

    @Test("light values are the Material 3 light tones of the same palettes")
    func lightValues() {
        #expect(hex(DesignColors.primary, .light) == "#3e5aa9")
        #expect(hex(DesignColors.background, .light) == "#f9f9fe")
        #expect(hex(DesignColors.onSurface, .light) == "#1a1c1f")
    }

    @Test("container fills and their on-colors are the same in both modes")
    func containersAreModeIndependent() {
        #expect(hex(DesignColors.primaryContainer, .light) == "#2563eb")
        #expect(hex(DesignColors.primaryContainer, .dark) == "#2563eb")
        #expect(hex(DesignColors.onPrimaryContainer, .light) == "#eeefff")
    }

    #if canImport(UIKit)
    @Test("Increase Contrast switches text to the extreme tone")
    func highContrastVariants() {
        func highContrastHex(_ color: Color, _ style: UIUserInterfaceStyle) -> String {
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: style),
                UITraitCollection(accessibilityContrast: .high)
            ])
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
        #expect(highContrastHex(DesignColors.onSurface, .light) == "#000000")
        #expect(highContrastHex(DesignColors.onSurface, .dark) == "#ffffff")
    }
    #endif

    @Test("text tokens reach 4.5:1 on their surfaces in both modes")
    func textContrast() {
        let pairs: [(Color, Color)] = [
            (DesignColors.onSurface, DesignColors.surface),
            (DesignColors.onSurface, DesignColors.surfaceContainerHigh),
            (DesignColors.onSurfaceVariant, DesignColors.surface),
            (DesignColors.onSurfaceVariant, DesignColors.surfaceContainer),
            (DesignColors.primary, DesignColors.surface),
            (DesignColors.onPrimary, DesignColors.primary),
            (DesignColors.onPrimaryContainer, DesignColors.primaryContainer),
            (DesignColors.onTertiary, DesignColors.tertiary),
            (DesignColors.onError, DesignColors.error)
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (foreground, background) in pairs {
                #expect(contrast(foreground, background, scheme) >= 4.5)
            }
        }
    }
}

@Suite("DesignTypography")
struct DesignTypographyTests {
    @Test("headlineLarge uses a 32pt bold weight, matching the Stitch theme")
    func headlineLargeSize() {
        #expect(DesignTypography.headlineLargeSize == 32)
        #expect(DesignTypography.headlineLargeWeight == .bold)
    }

    @Test("bodyLarge uses a 17pt regular weight, matching the Stitch theme")
    func bodyLargeSize() {
        #expect(DesignTypography.bodyLargeSize == 17)
        #expect(DesignTypography.bodyLargeWeight == .regular)
    }

    @Test("labelMono uses a 13pt medium weight, matching the Stitch theme")
    func labelMonoSize() {
        #expect(DesignTypography.labelMonoSize == 13)
        #expect(DesignTypography.labelMonoWeight == .medium)
    }
}

@Suite("DesignSpacing")
struct DesignSpacingTests {
    @Test("base unit is 4pt, matching the Stitch theme's baseline grid")
    func baseUnit() {
        #expect(DesignSpacing.base == 4)
    }

    @Test("container padding is 16pt")
    func containerPadding() {
        #expect(DesignSpacing.containerPadding == 16)
    }

    @Test("stack gap is 16pt and section gap is 24pt")
    func stackAndSectionGaps() {
        #expect(DesignSpacing.stackGap == 16)
        #expect(DesignSpacing.sectionGap == 24)
    }
}

@Suite("DesignShape")
struct DesignShapeTests {
    @Test("card corner radius is 24pt")
    func cardRadius() {
        #expect(DesignShape.cardCornerRadius == 24)
    }

    @Test("button corner radius is 12pt (Rounded Twelve)")
    func buttonRadius() {
        #expect(DesignShape.buttonCornerRadius == 12)
    }
}
