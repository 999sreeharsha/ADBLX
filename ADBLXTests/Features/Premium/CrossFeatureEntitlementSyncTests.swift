// ADBLXTests/Features/Premium/CrossFeatureEntitlementSyncTests.swift
import Foundation
import Testing
import ADBLXShared
@testable import ADBLX

@Suite("CrossFeatureEntitlementSync", .serialized)
struct CrossFeatureEntitlementSyncTests {
    private func createTempDirectory() -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossFeatureTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        return tempURL
    }

    private func readPersistedEntitlement(base: URL) -> WebExtensionPersistedEntitlement? {
        guard let url = WebExtensionAppGroupPaths.entitlementFileURL(base: base),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: data)
    }

    private func makeSampleManifest() -> FilterManifest {
        FilterManifest(
            manifestVersion: "1.0",
            entries: [
                FilterManifest.Entry(
                    id: "free-ads",
                    name: "Free Ads",
                    group: .ads,
                    sourceURL: URL(string: "https://example.com/ads.txt")!,
                    version: "1.0",
                    checksumSHA256: "abc",
                    ruleCount: 100,
                    enabledByDefault: true,
                    premium: false
                ),
                FilterManifest.Entry(
                    id: "premium-security",
                    name: "Premium Security",
                    group: .privacy,
                    sourceURL: URL(string: "https://example.com/security.txt")!,
                    version: "2.0",
                    checksumSHA256: "def",
                    ruleCount: 200,
                    enabledByDefault: true,
                    premium: true
                )
            ]
        )
    }

    @Test("Transition Matrix: .free -> .trial -> .monthly -> .free -> .lifetime")
    func completeTransitionMatrix() async throws {
        let tempBase = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let suiteName = "test_dns_sync_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settingsStore = DNSProtectionSettingsStore(userDefaults: defaults)

        let mockEntitlement = MockSubscriptionService(state: .free)
        let dnsService = RealDNSProtectionService(
            settingsStore: settingsStore,
            entitlementService: mockEntitlement
        )
        let webExtensionCoordinator = WebExtensionEntitlementCoordinator(
            entitlementService: mockEntitlement,
            baseAppGroupURL: tempBase
        )

        await webExtensionCoordinator.startObserving()
        await webExtensionCoordinator.syncCurrentState()

        let manifest = makeSampleManifest()

        // 1. Initial .free State
        #expect(mockEntitlement.currentState.hasPremiumAccess == false)
        #expect(readPersistedEntitlement(base: tempBase)?.state == .free)
        let freePlan = UpdatePlanner.plan(manifest: manifest, installed: [], isPremiumEntitled: false)
        #expect(freePlan.actions.contains(where: {
            if case .skipPremium = $0 { return true } else { return false }
        }))

        // 2. .free -> .trial
        settingsStore.setEnabled(true)
        let trialExpiry = Date().addingTimeInterval(15 * 86400)
        mockEntitlement.updateState(.trial(expiresAt: trialExpiry))
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(mockEntitlement.currentState.hasPremiumAccess == true)
        #expect(readPersistedEntitlement(base: tempBase)?.state == .premiumActive)
        let trialPlan = UpdatePlanner.plan(manifest: manifest, installed: [], isPremiumEntitled: true)
        let hasSkipInTrial = trialPlan.actions.contains(where: {
            if case .skipPremium = $0 { return true } else { return false }
        })
        #expect(hasSkipInTrial == false)

        // 3. .trial -> .monthly (Capability remains premiumActive)
        let monthExpiry = Date().addingTimeInterval(30 * 86400)
        mockEntitlement.updateState(.monthly(expiresAt: monthExpiry))
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(mockEntitlement.currentState == .monthly(expiresAt: monthExpiry))
        #expect(mockEntitlement.currentState.hasPremiumAccess == true)
        #expect(readPersistedEntitlement(base: tempBase)?.state == .premiumActive)
        
        let monthlyPlan = UpdatePlanner.plan(manifest: manifest, installed: [], isPremiumEntitled: true)
        let hasSkipInMonthly = monthlyPlan.actions.contains(where: {
            if case .skipPremium = $0 { return true } else { return false }
        })
        #expect(hasSkipInMonthly == false)
        #expect(monthlyPlan.actions.contains(where: {
            if case .install(let group, let entries) = $0, group == .privacy, entries.first?.id == "premium-security" {
                return true
            }
            return false
        }))

        // 4. .monthly -> .free (Downgrade: DNS tears down, WebExtension writes free, Updates halt premium)
        mockEntitlement.updateState(.free)
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(mockEntitlement.currentState.hasPremiumAccess == false)
        #expect(settingsStore.loadSettings().isEnabled == false)
        #expect(readPersistedEntitlement(base: tempBase)?.state == .free)

        let downgradedPlan = UpdatePlanner.plan(manifest: manifest, installed: [], isPremiumEntitled: false)
        #expect(downgradedPlan.actions.contains(where: {
            if case .skipPremium(let entry) = $0, entry.id == "premium-security" { return true }
            return false
        }))
        #expect(downgradedPlan.actions.contains(where: {
            if case .install(let group, let entries) = $0, group == .ads, entries.first?.id == "free-ads" {
                return true
            }
            return false
        }))

        // 5. .free -> .lifetime
        mockEntitlement.updateState(.lifetime)
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(mockEntitlement.currentState.hasPremiumAccess == true)
        #expect(readPersistedEntitlement(base: tempBase)?.state == .premiumActive)
        let lifetimePlan = UpdatePlanner.plan(manifest: manifest, installed: [], isPremiumEntitled: true)
        #expect(!lifetimePlan.actions.contains(where: {
            if case .skipPremium = $0 { return true } else { return false }
        }))

        _ = dnsService
    }
}
