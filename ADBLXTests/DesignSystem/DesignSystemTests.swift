// ADBLXTests/DesignSystem/DesignSystemTests.swift
import Testing
import SwiftUI
@testable import ADBLX

@Suite("DesignColors")
struct DesignColorsTests {
    @Test("primary matches the Stitch theme's Privacy Purple")
    func primaryMatchesTheme() {
        #expect(DesignColors.primary == Color(hex: "#3f3bbd"))
    }

    @Test("secondary matches the Stitch theme's Safety Blue")
    func secondaryMatchesTheme() {
        #expect(DesignColors.secondary == Color(hex: "#0058bc"))
    }

    @Test("background matches the Stitch theme's surface color")
    func backgroundMatchesTheme() {
        #expect(DesignColors.background == Color(hex: "#fcf8fb"))
    }
}

@Suite("DesignTypography")
struct DesignTypographyTests {
    @Test("headlineLarge uses a 34pt bold weight, matching the Stitch theme")
    func headlineLargeSize() {
        #expect(DesignTypography.headlineLargeSize == 34)
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
    @Test("base unit is 8pt, matching the Stitch theme's baseline grid")
    func baseUnit() {
        #expect(DesignSpacing.base == 8)
    }

    @Test("container padding is 20pt")
    func containerPadding() {
        #expect(DesignSpacing.containerPadding == 20)
    }

    @Test("stack gap is 16pt and section gap is 32pt")
    func stackAndSectionGaps() {
        #expect(DesignSpacing.stackGap == 16)
        #expect(DesignSpacing.sectionGap == 32)
    }
}

@Suite("DesignShape")
struct DesignShapeTests {
    @Test("card corner radius is 24pt (rounded-xl)")
    func cardRadius() {
        #expect(DesignShape.cardCornerRadius == 24)
    }

    @Test("button corner radius is 16pt (rounded-lg)")
    func buttonRadius() {
        #expect(DesignShape.buttonCornerRadius == 16)
    }
}
