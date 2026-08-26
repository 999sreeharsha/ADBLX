// ADBLXTests/Features/Premium/EntitlementTeardownTests.swift
import Testing
import Foundation
@testable import ADBLX
import ADBLXShared

@Suite("EntitlementTeardown", .serialized)
struct EntitlementTeardownTests {
    @Test("Transitioning from .annual to .free triggers reactive DNS teardown")
    func reactiveTeardownOnEntitlementLoss() async throws {
        let tempDefaults = UserDefaults(suiteName: "TeardownTest_\(UUID().uuidString)")!
        let settingsStore = DNSProtectionSettingsStore(userDefaults: tempDefaults)
        
        // Start in enabled state with active annual subscription
        settingsStore.setEnabled(true)
        let initialDate = Date().addingTimeInterval(365 * 86400)
        let mockEntitlement = MockSubscriptionService(state: .annual(expiresAt: initialDate))
        
        let service = RealDNSProtectionService(
            settingsStore: settingsStore,
            entitlementService: mockEntitlement
        )
        
        // Entitlement lapses -> transitions to .free
        mockEntitlement.updateState(.free)
        
        // Give background detached task a brief moment to process stream event
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Settings store must be disabled
        let updatedSettings = settingsStore.loadSettings()
        #expect(updatedSettings.isEnabled == false)
    }

    @Test("Repeated .free entitlement signals are idempotent and do not crash or corrupt settings")
    func repeatedFreeSignalsAreIdempotent() async throws {
        let tempDefaults = UserDefaults(suiteName: "TeardownIdempotent_\(UUID().uuidString)")!
        let settingsStore = DNSProtectionSettingsStore(userDefaults: tempDefaults)
        settingsStore.setEnabled(false)

        let mockEntitlement = MockSubscriptionService(state: .free)
        let service = RealDNSProtectionService(
            settingsStore: settingsStore,
            entitlementService: mockEntitlement
        )

        // Multiple repeated .free signals
        mockEntitlement.updateState(.free)
        mockEntitlement.updateState(.free)
        mockEntitlement.updateState(.free)

        try await Task.sleep(nanoseconds: 50_000_000)

        let settings = settingsStore.loadSettings()
        #expect(settings.isEnabled == false)
    }
}
