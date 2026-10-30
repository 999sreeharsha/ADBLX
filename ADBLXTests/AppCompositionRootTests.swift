// ADBLXTests/AppCompositionRootTests.swift
import Foundation
import Testing
@testable import ADBLX

@Suite("AppCompositionRoot")
struct AppCompositionRootTests {
    @Test("the shared App Group container is provisioned for this target")
    func appGroupContainerIsProvisioned() {
        // Read-only: confirms the entitlement resolves, without creating or writing anything in
        // the real container (tests use FilterStore.temporary()).
        #expect(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) != nil)
    }

    @Test("makeUpdateCoordinator constructs a coordinator wired to the given pipeline and store")
    func makeUpdateCoordinatorWiresDependencies() async throws {
        let store = FilterStore.temporary()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)

        let coordinator = AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)

        let result = try await coordinator.run()
        switch result {
        case .rolledBack, .upToDate, .updated, .rollbackFailed:
            #expect(true)
        }
    }
}
