import Testing
import Foundation
@testable import ADBLX

/// A signed manifest can move a list to another group (a deliberate regrouping, or a publishing
/// mistake). The list must end up recorded once, in its new group, and compiled only there.
/// Before the fix, the old record stayed beside a new one with the same ID, and the next update
/// trapped in `UpdatePlanner` on every launch that saw a new manifest.
@Suite("A list moving to another group", .serialized)
struct GroupMoveTests {
    private let manifestEndpoint = URL(string: "https://example.com/manifest.json")!
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )
    private let oldRules = Data("[{\"trigger\":{\"url-filter\":\"old\"},\"action\":{\"type\":\"block\"}}]".utf8)
    private let newRules = Data("[{\"trigger\":{\"url-filter\":\"new\"},\"action\":{\"type\":\"block\"}}]".utf8)

    private func installed(_ id: String, group: FilterGroup, checksum: String = "checksum-a") -> InstalledFilter {
        InstalledFilter(id: id, group: group, installedVersion: "1", checksumSHA256: checksum,
                        lastUpdated: Date(timeIntervalSince1970: 0), ruleCount: 1)
    }

    private func entry(_ id: String, group: FilterGroup, checksum: String = "checksum-a") -> FilterManifest.Entry {
        FilterManifest.Entry(id: id, name: id, group: group,
                             sourceURL: SignedManifests.sourceURL(manifestEndpoint, group: group, id: id),
                             version: "1", checksumSHA256: checksum, ruleCount: 1,
                             enabledByDefault: true, premium: false)
    }

    private func makePipeline(_ store: FilterStore) -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
    }

    private func installedFilters(_ store: FilterStore) async throws -> [InstalledFilter] {
        try JSONDecoder().decode([InstalledFilter].self, from: try await store.read("installed_filters.json", in: .metadata))
    }

    private func compiledSourceIDs(_ store: FilterStore, _ group: FilterGroup) async throws -> [String] {
        let data = try await store.read(CompiledSources.filename(for: group), in: .compiled)
        return try JSONDecoder().decode(CompiledSources.self, from: data).sourceIDs
    }

    @Test("the planner tolerates a list recorded twice, as an affected install may already have")
    func plannerToleratesDuplicateRecords() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry("easylist", group: .privacy, checksum: "checksum-b")])
        let plan = UpdatePlanner.plan(
            manifest: manifest,
            installed: [installed("easylist", group: .ads), installed("easylist", group: .privacy)],
            isPremiumEntitled: false
        )
        #expect(plan.actions.contains(.install(group: .privacy, entries: [entry("easylist", group: .privacy, checksum: "checksum-b")])))
    }

    @Test("a list whose only change is its group is reinstalled in the new group")
    func groupChangeAloneReinstalls() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry("easylist", group: .privacy)])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [installed("easylist", group: .ads)], isPremiumEntitled: false)
        #expect(plan.actions == [.install(group: .privacy, entries: [entry("easylist", group: .privacy)])])
    }

    @Test("installing a list already recorded in another group moves its record instead of adding one")
    func pipelineMovesTheRecord() async throws {
        let store = FilterStore.temporary()
        let pipeline = makePipeline(store)
        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [
            FilterSource(filterID: "easylist", version: "1", checksumSHA256: Checksum.sha256Hex(of: oldRules), data: oldRules)
        ]), reloadStrategy: .deferred)

        _ = try await pipeline.install(GroupComposition(group: .privacy, sources: [
            FilterSource(filterID: "easylist", version: "2", checksumSHA256: Checksum.sha256Hex(of: newRules), data: newRules)
        ]), reloadStrategy: .deferred)

        let records = try await installedFilters(store).filter { $0.id == "easylist" }
        #expect(records.map(\.group) == [.privacy])
        #expect(records.map(\.installedVersion) == ["2"])
    }

    @Test("an update that moves a list leaves it recorded once, compiled only in its new group, and the next update runs")
    func updateMovesTheListAndKeepsWorking() async throws {
        let store = FilterStore.temporary()
        let pipeline = makePipeline(store)
        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [
            FilterSource(filterID: "easylist", version: "1", checksumSHA256: Checksum.sha256Hex(of: oldRules), data: oldRules)
        ]), reloadStrategy: .deferred)

        let moved = entry("easylist", group: .privacy, checksum: Checksum.sha256Hex(of: newRules))
        let manifestData = try JSONEncoder().encode(FilterManifest(manifestVersion: SignedManifests.version, entries: [moved]))
        func coordinator(etag: String) -> UpdateCoordinator {
            let session = MockHTTPSession(responses: [
                manifestEndpoint: .success((manifestData, HTTPURLResponse(
                    url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": etag])!)),
                moved.sourceURL: .success((newRules, HTTPURLResponse(
                    url: moved.sourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)),
            ])
            return UpdateCoordinator(
                manifestClient: SignedManifests.signingClient(session: session, endpoint: manifestEndpoint),
                manifestStore: ManifestStore(filterStore: store),
                downloadClient: FilterDownloadClient(session: session),
                pipeline: pipeline, store: store, reloader: ReloadCoordinator(),
                extensionIdentifiers: ids, entitlementService: StubEntitlementService(isPremiumEntitled: false)
            )
        }

        _ = try await coordinator(etag: "\"v1\"").run()

        let records = try await installedFilters(store).filter { $0.id == "easylist" }
        // Stop here on failure: with a duplicate record, the second run below traps.
        try #require(records.count == 1, "easylist is recorded \(records.count) times")
        #expect(records.first?.group == .privacy)
        #expect(try await compiledSourceIDs(store, .privacy) == ["easylist"])
        #expect(try await !compiledSourceIDs(store, .ads).contains("easylist"))

        // A new ETag makes the next run plan again instead of stopping at a 304.
        _ = try await coordinator(etag: "\"v2\"").run()
        #expect(try await installedFilters(store).filter { $0.id == "easylist" }.count == 1)
    }
}
