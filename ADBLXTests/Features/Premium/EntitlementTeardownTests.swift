// ADBLXTests/Features/Premium/EntitlementTeardownTests.swift
import Testing
import Foundation
@testable import ADBLX
import ADBLXShared

/// Teardown runs on a detached task, so each test waits for the service to report it
/// (`.disconnected`, sent after the settings are written) rather than sleeping. That report is
/// skipped only when a tunnel configuration exists and is already off; the simulator has none
/// (`loadAllFromPreferences` fails), so here it always comes, and a missing one hits the time limit.
@Suite("EntitlementTeardown", .serialized, .timeLimit(.minutes(1)))
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
        let statuses = TestSignal<DNSConnectionStatus>()
        service.setStatusChangeHandler { statuses.send($0) }

        // Entitlement lapses -> transitions to .free
        mockEntitlement.updateState(.free)
        await statuses.wait { $0 == .disconnected }

        // Settings store must be disabled
        let updatedSettings = settingsStore.loadSettings()
        #expect(updatedSettings.isEnabled == false)
    }

    @Test("Repeated .free entitlement signals are idempotent and do not crash or corrupt settings")
    func repeatedFreeSignalsAreIdempotent() async throws {
        let tempDefaults = UserDefaults(suiteName: "TeardownIdempotent_\(UUID().uuidString)")!
        let settingsStore = DNSProtectionSettingsStore(userDefaults: tempDefaults)
        settingsStore.setEnabled(false)

        // Premium at first, so the service's teardown can't run before the handler below is set.
        let mockEntitlement = MockSubscriptionService(state: .annual(expiresAt: Date().addingTimeInterval(86400)))
        let service = RealDNSProtectionService(
            settingsStore: settingsStore,
            entitlementService: mockEntitlement
        )
        let statuses = TestSignal<DNSConnectionStatus>()
        service.setStatusChangeHandler { statuses.send($0) }

        // Multiple repeated .free signals. The mock drops a repeat of its current state, so the
        // service handles one teardown, with the settings already off.
        mockEntitlement.updateState(.free)
        mockEntitlement.updateState(.free)
        mockEntitlement.updateState(.free)
        await statuses.wait { $0 == .disconnected }

        let settings = settingsStore.loadSettings()
        #expect(settings.isEnabled == false)
    }
}
