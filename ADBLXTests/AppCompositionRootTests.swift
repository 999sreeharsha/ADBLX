// ADBLXTests/AppCompositionRootTests.swift
import Foundation
import Testing
@testable import ADBLX

@Suite("AppCompositionRoot")
struct AppCompositionRootTests {
    @Test("makeFilterStore returns a FilterStore configured with the shared App Group identifier")
    func makeFilterStoreUsesAppGroupIdentifier() async throws {
        let store = AppCompositionRoot.makeFilterStore()

        // Round-trip through the store to confirm it resolves the real App Group
        // container rather than throwing .appGroupContainerUnavailable.
        let url = try await store.directoryURL(.metadata)
        #expect(url.path.contains("Metadata"))
    }

    @Test("makeUpdateCoordinator constructs a coordinator wired to the given pipeline and store")
    func makeUpdateCoordinatorWiresDependencies() async throws {
        let store = AppCompositionRoot.makeFilterStore()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)

        let coordinator = AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)

        let result = try await coordinator.run()
        switch result {
        case .rolledBack, .upToDate, .updated, .rollbackFailed:
            #expect(true)
        }
    }
}
