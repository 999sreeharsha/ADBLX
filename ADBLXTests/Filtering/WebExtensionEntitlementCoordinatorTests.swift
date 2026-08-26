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

        // 2. .trial -> .monthly (Capability remains premiumActive -> deduplicated)
        let monthExpiry = Date().addingTimeInterval(30 * 86400)
        let beforeTime = readPersistedEntitlement(base: tempBase)?.updatedAt
        mockEntitlement.updateState(.monthly(expiresAt: monthExpiry))
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterTime = readPersistedEntitlement(base: tempBase)?.updatedAt
        #expect(afterTime == beforeTime) // No extra write because capability didn't change

        // 3. .monthly -> .free (Capability downgraded -> writes free)
        mockEntitlement.updateState(.free)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(readPersistedEntitlement(base: tempBase)?.state == .free)
    }
}
