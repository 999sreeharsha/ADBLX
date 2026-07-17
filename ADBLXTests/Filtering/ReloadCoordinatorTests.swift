// ADBLXTests/Filtering/ReloadCoordinatorTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("ReloadCoordinator")
struct ReloadCoordinatorTests {
    @Test("returns a failed result with a captured error for an unknown extension identifier, bounded by the timeout")
    func failsGracefullyForUnknownIdentifier() async {
        let coordinator = ReloadCoordinator(timeoutSeconds: 3)
        let result = await coordinator.reload(extensionIdentifier: "com.ADBLX.does-not-exist")

        #expect(result.extensionIdentifier == "com.ADBLX.does-not-exist")
        #expect(result.success == false)
        #expect(result.error != nil)
    }

    @Test("reload(extensionIdentifiers:) returns one result per identifier, in order")
    func reloadsMultipleInOrder() async {
        let coordinator = ReloadCoordinator(timeoutSeconds: 3)
        let results = await coordinator.reload(extensionIdentifiers: ["a", "b"])
        #expect(results.map(\.extensionIdentifier) == ["a", "b"])
    }
}
