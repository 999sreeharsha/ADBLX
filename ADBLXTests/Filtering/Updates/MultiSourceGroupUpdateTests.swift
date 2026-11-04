import Testing
import Foundation
@testable import ADBLX

/// A group can have several sources (Annoyances: Fanboy + SHIELD fixes). Updating one source
/// must recompile the group from all of its sources, not just the changed one.
@Suite("UpdateCoordinator multi-source groups", .serialized)
struct MultiSourceGroupUpdateTests {
    private let manifestEndpoint = URL(string: "https://example.com/manifest.json")!
    private let urlA = URL(string: "https://example.com/a.txt")!
    private let urlB = URL(string: "https://example.com/b.txt")!
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    private func rules(_ host: String) -> Data {
        Data("[{\"trigger\":{\"url-filter\":\"\(host)\\\\.example\"},\"action\":{\"type\":\"block\"}}]".utf8)
    }

    private func entry(_ id: String, url: URL, version: String, payload: Data) -> FilterManifest.Entry {
        FilterManifest.Entry(
            id: id, name: id, group: .annoyances, sourceURL: url, version: version,
            checksumSHA256: Checksum.sha256Hex(of: payload), ruleCount: 1,
            enabledByDefault: false, premium: true
        )
    }

    private func run(
        installed: [(id: String, version: String, payload: Data)],
        manifest entries: [FilterManifest.Entry],
        downloads: [URL: Data]
    ) async throws -> (compiledRuleCount: Int, filterIDs: [String]) {
        let store = FilterStore.temporary()
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        _ = try await pipeline.install(GroupComposition(group: .annoyances, sources: installed.map {
            FilterSource(filterID: $0.id, version: $0.version, checksumSHA256: Checksum.sha256Hex(of: $0.payload),
                         data: $0.payload, premium: true)
        }), reloadStrategy: .deferred)

        var responses: [URL: Result<(Data, URLResponse), Error>] = [
            manifestEndpoint: .success((
                try JSONEncoder().encode(FilterManifest(manifestVersion: "2", entries: entries)),
                HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v2\""])!
            ))
        ]
        for (url, data) in downloads {
            responses[url] = .success((data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        }
        let session = MockHTTPSession(responses: responses)
        let coordinator = UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: ids,
            entitlementService: StubEntitlementService(isPremiumEntitled: true)
        )
        _ = try await coordinator.run()

        let compiled = try JSONSerialization.jsonObject(with: try await store.read("Annoyances.json", in: .compiled)) as? [Any]
        let installedFilters = try JSONDecoder().decode(
            [InstalledFilter].self, from: try await store.read("installed_filters.json", in: .metadata)
        )
        return (compiled?.count ?? 0, installedFilters.map(\.id).sorted())
    }

    @Test("a new source added beside an unchanged one keeps the unchanged source's rules")
    func newSourceKeepsExisting() async throws {
        let a = rules("a"), b = rules("b")
        let result = try await run(
            installed: [("a", "1", a)],
            manifest: [entry("a", url: urlA, version: "1", payload: a), entry("b", url: urlB, version: "1", payload: b)],
            downloads: [urlB: b]
        )
        #expect(result.compiledRuleCount == 2)
        #expect(result.filterIDs == ["a", "b"])
    }

    @Test("a changed source beside an unchanged one keeps the unchanged source's rules")
    func changedSourceKeepsSibling() async throws {
        let a = rules("a"), a2 = rules("a2"), b = rules("b")
        let result = try await run(
            installed: [("a", "1", a), ("b", "1", b)],
            manifest: [entry("a", url: urlA, version: "2", payload: a2), entry("b", url: urlB, version: "1", payload: b)],
            downloads: [urlA: a2]
        )
        #expect(result.compiledRuleCount == 2)
        #expect(result.filterIDs == ["a", "b"])
    }
}
