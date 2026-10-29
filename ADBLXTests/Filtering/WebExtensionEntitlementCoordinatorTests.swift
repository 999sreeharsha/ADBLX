// ADBLXTests/Filtering/WebExtensionEntitlementCoordinatorTests.swift
import Foundation
import Testing
import ADBLXShared
@testable import ADBLX

@Suite("WebExtensionEntitlementCoordinator", .serialized)
struct WebExtensionEntitlementCoordinatorTests {
    private func createTempDirectory() -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebExtensionCoordinatorTest-\(UUID().uuidString)")
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

    @Test("Initial synchronization writes correct state")
    func initialSyncWritesState() async throws {
        let tempBase = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let mockEntitlement = MockSubscriptionService(state: .free)
        let coordinator = WebExtensionEntitlementCoordinator(
            entitlementService: mockEntitlement,
            baseAppGroupURL: tempBase
        )

        await coordinator.syncCurrentState()
        let persisted = readPersistedEntitlement(base: tempBase)
        #expect(persisted?.state == .free)
    }

    @Test("Transitions update App Group entitlement.json and deduplicate redundant writes")
    func transitionsAndDeduplication() async throws {
        let tempBase = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let mockEntitlement = MockSubscriptionService(state: .free)
        let coordinator = WebExtensionEntitlementCoordinator(
            entitlementService: mockEntitlement,
            baseAppGroupURL: tempBase
        )

        await coordinator.startObserving()
        await coordinator.syncCurrentState()

        #expect(readPersistedEntitlement(base: tempBase)?.state == .free)

        // 1. .free -> .trial
        let trialExpiry = Date().addingTimeInterval(15 * 86400)
        mockEntitlement.updateState(.trial(expiresAt: trialExpiry))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(readPersistedEntitlement(base: tempBase)?.state == .premiumActive)

        #expect(readPersistedEntitlement(base: tempBase)?.validUntil == trialExpiry.timeIntervalSince1970)

        // 2. .trial -> .monthly (still premiumActive, but validUntil differs -> republished)
        let monthExpiry = Date().addingTimeInterval(30 * 86400)
        mockEntitlement.updateState(.monthly(expiresAt: monthExpiry))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(readPersistedEntitlement(base: tempBase)?.state == .premiumActive)
        #expect(readPersistedEntitlement(base: tempBase)?.validUntil
            == monthExpiry.addingTimeInterval(7 * 86400).timeIntervalSince1970)

        // 2b. Identical (isPremium, validUntil) is deduplicated -> no extra write.
        let beforeTime = readPersistedEntitlement(base: tempBase)?.updatedAt
        await coordinator.syncCurrentState()
        #expect(readPersistedEntitlement(base: tempBase)?.updatedAt == beforeTime)

        // 3. .monthly -> .free (Capability downgraded -> writes free)
        mockEntitlement.updateState(.free)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(readPersistedEntitlement(base: tempBase)?.state == .free)
        #expect(readPersistedEntitlement(base: tempBase)?.validUntil == nil)
    }

    @Test("Lifetime publishes premiumActive with no validUntil")
    func lifetimeHasNoExpiry() async throws {
        let tempBase = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let coordinator = WebExtensionEntitlementCoordinator(
            entitlementService: MockSubscriptionService(state: .lifetime),
            baseAppGroupURL: tempBase
        )
        await coordinator.syncCurrentState()
        let persisted = readPersistedEntitlement(base: tempBase)
        #expect(persisted?.state == .premiumActive)
        #expect(persisted?.validUntil == nil)
    }
}
