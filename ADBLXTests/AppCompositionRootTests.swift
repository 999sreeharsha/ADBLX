// ADBLXTests/AppCompositionRootTests.swift
import CryptoKit
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

    // No network: a stub serves a manifest signed with the test key at the production URL.
    // Whether the live site works is the disabled live suite's job and the release checklist's.
    private func coordinator(trustedKeys: [P256.Signing.PublicKey]? = nil) -> UpdateCoordinator {
        let store = FilterStore.temporary()
        let endpoint = AppManifestEndpointProvider().manifestURL
        let manifest = FilterManifest(manifestVersion: SignedManifests.version, entries: [])
        let session = SigningSession(MockHTTPSession(responses: [
            endpoint: .success((try! JSONEncoder().encode(manifest), HTTPURLResponse(
                url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil
            )!))
        ]))
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        guard let trustedKeys else {
            return AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store, session: session)
        }
        return AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store, session: session, trustedKeys: trustedKeys)
    }

    @Test("makeUpdateCoordinator checks manifests against the production key list")
    func makeUpdateCoordinatorUsesTheProductionKeys() async {
        await #expect(throws: ManifestRejection.signature) {
            _ = try await coordinator().run()
        }
    }

    @Test("makeUpdateCoordinator accepts a manifest signed by the keys it is given, from the production site")
    func makeUpdateCoordinatorAcceptsTheGivenKeys() async throws {
        let result = try await coordinator(trustedKeys: [SignedManifests.key.publicKey]).run()

        switch result {
        case .upToDate, .updated:
            #expect(true)
        case .rolledBack, .rollbackFailed:
            Issue.record("expected an accepted manifest, got \(result)")
        }
    }
}
