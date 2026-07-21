// ADBLXTests/DesignSystem/DesignSystemTests.swift
import Testing
import SwiftUI
@testable import ADBLX

@Suite("DesignColors")
struct DesignColorsTests {
    @Test("primary matches the Serene Shield Unified theme's dark-mode blue")
    func primaryMatchesTheme() {
        #expect(DesignColors.primary == Color(hex: "#b4c5ff"))
    }

    @Test("secondary matches the Serene Shield Unified theme's protection green")
    func secondaryMatchesTheme() {
        #expect(DesignColors.secondary == Color(hex: "#53e16f"))
    }

    @Test("background matches the Serene Shield Unified theme's dark surface color")
    func backgroundMatchesTheme() {
        #expect(DesignColors.background == Color(hex: "#111317"))
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
