import Testing
@testable import ADBLX

/// DNS Protection can't ship until its connectivity bug is closed (`docs/gotchas.md`), so a
/// build without the flag must not mention it anywhere a user could see it.
@Suite("DNS hidden by the build flag")
struct DNSVisibilityTests {
    @Test("the paywall list has no DNS entry with the flag off")
    func paywallFeatures() {
        #expect(PremiumFeature.displayOrder(focus: nil, dnsEnabled: false) == [.premiumFilterLists, .backgroundUpdates, .youtube])
        #expect(PremiumFeature.displayOrder(focus: .youtube, dnsEnabled: false) == [.youtube, .premiumFilterLists, .backgroundUpdates])
    }

    @Test("a paywall focused on DNS still has no DNS entry with the flag off")
    func paywallFocus() {
        #expect(PremiumFeature.displayOrder(focus: .dnsProtection, dnsEnabled: false) == [.premiumFilterLists, .backgroundUpdates, .youtube])
    }

    @Test("the paywall comparison has no DNS row with the flag off")
    func paywallComparison() {
        #expect(PremiumComparisonRow.visible(dnsEnabled: false) == [.safariBlocking, .autoUpdates, .premiumThemes])
        #expect(PremiumComparisonRow.visible(dnsEnabled: true) == [.safariBlocking, .dnsProtection, .autoUpdates, .premiumThemes])
    }

    @Test("onboarding has no DNS row with the flag off")
    func onboarding() {
        #expect(TrialHighlight.visible(dnsEnabled: false) == [.safari, .tracking])
        #expect(TrialHighlight.visible(dnsEnabled: true) == [.dns, .safari, .tracking])
    }

    @Test("Home has no DNS stat with the flag off")
    func homeStats() {
        #expect(HomeStatTile.visible(dnsEnabled: false) == [.safari, .lastUpdate, .rules])
        #expect(HomeStatTile.visible(dnsEnabled: true) == [.safari, .dns, .lastUpdate, .rules])
    }

    @Test("the Protection tab has no DNS row with the flag off")
    func protectionRows() {
        #expect(ProtectionConfigurationRow.visible(dnsEnabled: false) == [.advancedFilterLists, .speedOptimization, .brokenSiteReport])
        #expect(ProtectionConfigurationRow.visible(dnsEnabled: true) == [.advancedFilterLists, .dnsProtection, .speedOptimization, .brokenSiteReport])
    }

    @Test("the build's own flag decides the defaults")
    func defaultsFollowTheBuild() {
        #if DNS_PROTECTION_ENABLED
        #expect(BuildFeatures.dnsProtection)
        #else
        #expect(!BuildFeatures.dnsProtection)
        #endif
        #expect(PremiumFeature.displayOrder(focus: nil).contains(.dnsProtection) == BuildFeatures.dnsProtection)
        #expect(HomeStatTile.visible().contains(.dns) == BuildFeatures.dnsProtection)
        #expect(TrialHighlight.visible().contains(.dns) == BuildFeatures.dnsProtection)
        #expect(PremiumComparisonRow.visible().contains(.dnsProtection) == BuildFeatures.dnsProtection)
        #expect(ProtectionConfigurationRow.visible().contains(.dnsProtection) == BuildFeatures.dnsProtection)
    }
}
