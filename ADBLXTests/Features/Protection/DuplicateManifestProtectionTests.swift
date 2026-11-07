import Foundation
import Testing
@testable import ADBLX

/// `RealProtectionService.fetchStatus()` lists `installed_filters.json` as it is, with no
/// de-duplication. That is safe only because a manifest with a repeated ID is rejected before
/// anything is installed (`ManifestVerifier`, `.duplicate`). This proves the whole chain, so
/// the old `filterLists` dedup gotcha can stay closed.
@Suite("Duplicate-ID manifest never reaches the Protection screen", .serialized)
struct DuplicateManifestProtectionTests {
    private let endpoint = URL(string: "https://example.com/adblx/manifest.json")!
    private let ids = AppCompositionRoot.extensionIdentifiers

    @Test("A manifest listing one ID twice is rejected, and the Protection screen still lists each installed list once")
    func duplicateIDNeverReachesProtection() async throws {
        let store = FilterStore.temporary()
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator(), gate: FilterTransactionGate()
        )
        for (group, id) in [(FilterGroup.ads, "easylist"), (.privacy, "easyprivacy")] {
            let rules = Data("[{\"trigger\":{\"url-filter\":\"\(id)\"},\"action\":{\"type\":\"block\"}}]".utf8)
            _ = try await pipeline.install(GroupComposition(group: group, sources: [FilterSource(
                filterID: id, version: "v1", checksumSHA256: Checksum.sha256Hex(of: rules), data: rules
            )]), reloadStrategy: .deferred)
        }
        let installedBefore = try await store.read("installed_filters.json", in: .metadata)

        // The same ID in two groups, each entry valid on its own.
        let body = Data("[{\"trigger\":{\"url-filter\":\"new\"},\"action\":{\"type\":\"block\"}}]".utf8)
        let entries = [FilterGroup.ads, .privacy].map { group in
            FilterManifest.Entry(
                id: "easylist", name: "EasyList", group: group,
                sourceURL: SignedManifests.sourceURL(endpoint, group: group, id: "easylist"),
                version: "v2", checksumSHA256: Checksum.sha256Hex(of: body), ruleCount: 1,
                enabledByDefault: true, premium: false
            )
        }
        let manifest = FilterManifest(manifestVersion: SignedManifests.version, entries: entries)
        var responses: [URL: Result<(Data, URLResponse), Error>] = [
            endpoint: .success((try JSONEncoder().encode(manifest), HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        ]
        for entry in entries {
            responses[entry.sourceURL] = .success((body, HTTPURLResponse(url: entry.sourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        }
        let session = MockHTTPSession(responses: responses)
        let coordinator = UpdateCoordinator(
            manifestClient: SignedManifests.signingClient(session: session, endpoint: endpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(), extensionIdentifiers: ids,
            entitlementService: StubEntitlementService(isPremiumEntitled: false), gate: FilterTransactionGate()
        )

        await #expect(throws: ManifestRejection.duplicate) { _ = try await coordinator.run() }

        #expect(try await store.read("installed_filters.json", in: .metadata) == installedBefore)
        let status = await RealProtectionService(store: store, preferencesStore: FilterPreferencesStore(store: store)).fetchStatus()
        #expect(status.filterLists.map(\.id).sorted() == ["easylist", "easyprivacy"])
    }
}
