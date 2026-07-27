// ADBLXTests/Filtering/FilterPipelineTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("FilterPipeline", .serialized)
struct FilterPipelineTests {
    private let groupExtensionIdentifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    private func makePipeline() -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: FilterStore(appGroupIdentifier: AppGroup.identifier),
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator()
        )
    }

    @Test("installs the bundled Ads snapshot end-to-end and returns a populated PipelineResult")
    func installsBundledSnapshotEndToEnd() async throws {
        let pipeline = makePipeline()
        let result = try await pipeline.installBundledSnapshotIfNeeded()

        #expect(result.group == .ads)
        #expect(result.compiledRuleCount == 70)
        #expect(result.installedRuleCount == 70)
        #expect(result.compileStatistics.rulesLoaded == 70)
        #expect(result.reloadResults.count == 1)
        #expect(result.reloadResults[0].extensionIdentifier == "com.ADBLX.ADBLX.AdsBlocker")

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let compiledDir = try await store.directoryURL(.compiled)
        let writtenData = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))
        let writtenRules = try JSONSerialization.jsonObject(with: writtenData) as? [Any]
        #expect(writtenRules?.count == 70)

        let metadataDir = try await store.directoryURL(.metadata)
        #expect(FileManager.default.fileExists(atPath: metadataDir.appendingPathComponent("installed_filters.json").path))
        #expect(FileManager.default.fileExists(atPath: metadataDir.appendingPathComponent("statistics.json").path))
    }

    @Test("throws when a source fails validation")
    func throwsOnInvalidSource() async {
        let pipeline = makePipeline()
        let composition = GroupComposition(
            group: .ads,
            sources: [FilterSource(filterID: "bad", version: "v1", checksumSHA256: "a", data: Data())]
        )
        await #expect(throws: FilterValidator.ValidationError.self) {
            _ = try await pipeline.install(composition)
        }
    }

    @Test("reloadStrategy .deferred skips the reload call and returns empty reloadResults")
    func deferredReloadSkipsReloadCall() async throws {
        let pipeline = makePipeline()
        let source = FilterSource(
            filterID: "deferred-test", version: "v1", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let composition = GroupComposition(group: .ads, sources: [source])

        let result = try await pipeline.install(composition, reloadStrategy: .deferred)

        #expect(result.reloadResults.isEmpty)
    }

    @Test("installing a second composition after a first accumulates both filters in installed_filters.json")
    func installingSecondCompositionAccumulatesMetadata() async throws {
        let pipeline = makePipeline()
        let source = { (id: String) in
            FilterSource(
                filterID: id, version: "v1", checksumSHA256: "a",
                data: Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
            )
        }

        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [source("filter-a")]), reloadStrategy: .deferred)
        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [source("filter-b")]), reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(Set(filters.map(\.id)).isSuperset(of: ["filter-a", "filter-b"]))
    }

    @Test("re-installing the same filterID replaces its entry instead of duplicating it")
    func reinstallingSameFilterIDReplacesEntry() async throws {
        let pipeline = makePipeline()
        let source = FilterSource(
            filterID: "filter-a", version: "v1", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let composition = GroupComposition(group: .ads, sources: [source])

        _ = try await pipeline.install(composition, reloadStrategy: .deferred)
        _ = try await pipeline.install(composition, reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(filters.filter { $0.id == "filter-a" }.count == 1)
    }

    @Test("install(composition:) records each source's passed version, not a bundled-snapshot default")
    func installRecordsPassedVersion() async throws {
        let pipeline = makePipeline()
        let source = FilterSource(
            filterID: "filter-versioned", version: "2026-07-18", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let composition = GroupComposition(group: .ads, sources: [source])

        _ = try await pipeline.install(composition, reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(filters.first(where: { $0.id == "filter-versioned" })?.installedVersion == "2026-07-18")
    }

    @Test("install(composition:) composes multiple sources into one Compiled/Ads.json write and two metadata entries")
    func installComposesMultipleSourcesIntoOneWrite() async throws {
        let pipeline = makePipeline()
        let easyList = FilterSource(
            filterID: "easylist", version: "2026-07-19", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\"a.*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let peterLowe = FilterSource(
            filterID: "peter-lowe", version: "2026-07-19", checksumSHA256: "b",
            data: Data("[{\"trigger\":{\"url-filter\":\"b.*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let composition = GroupComposition(group: .ads, sources: [easyList, peterLowe])

        let result = try await pipeline.install(composition, reloadStrategy: .deferred)

        #expect(result.group == .ads)
        #expect(result.compiledRuleCount == 2)
        #expect(result.installedRuleCount == 2)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let compiledDir = try await store.directoryURL(.compiled)
        let writtenData = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))
        let writtenRules = try JSONSerialization.jsonObject(with: writtenData) as? [Any]
        #expect(writtenRules?.count == 2)

        let metadataDir = try await store.directoryURL(.metadata)
        let metadataData = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: metadataData)
        #expect(Set(filters.map(\.id)).isSuperset(of: ["easylist", "peter-lowe"]))
    }

    @Test("install persists each source's raw payload to Filters/<filterID>.json")
    func installPersistsRawPayloadToFiltersDirectory() async throws {
        let pipeline = makePipeline()
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let payload = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        let source = FilterSource(filterID: "persist-test", version: "v1", checksumSHA256: "a", data: payload)
        let composition = GroupComposition(group: .ads, sources: [source])

        _ = try await pipeline.install(composition, reloadStrategy: .deferred)

        let readBack = try await store.readFilterPayload(filterID: "persist-test")
        #expect(readBack == payload)

        let filtersDir = try await store.directoryURL(.filters)
        try? FileManager.default.removeItem(at: filtersDir.appendingPathComponent("persist-test.json"))
    }

    /// Resets `.ads`-group `installed_filters.json` entries and their `Filters/*.json`
    /// payloads to empty. Several tests in this `.serialized` suite install into `.ads`
    /// and only clean up their own `Filters/<id>.json` payload afterward, never their
    /// `installed_filters.json` entry (a pre-existing gap — other tests in this file work
    /// around it with `Set`/`isSuperset` assertions instead of exact-match ones). `remove()`
    /// is the first pipeline operation that reads back *every* `.ads` group member's raw
    /// payload from `Filters/` to recompose, so a stale metadata entry whose payload file
    /// is already gone breaks it immediately. Tests exercising `remove()` need a genuinely
    /// clean `.ads` group, not just a clean slate for their own filterIDs.
    private func resetAdsGroup(store: FilterStore) async throws {
        let metadataDir = try await store.directoryURL(.metadata)
        let filtersDir = try await store.directoryURL(.filters)
        let metadataFile = metadataDir.appendingPathComponent("installed_filters.json")
        var filters: [InstalledFilter] = []
        if let data = try? Data(contentsOf: metadataFile),
           let decoded = try? JSONDecoder().decode([InstalledFilter].self, from: data) {
            filters = decoded
        }
        for filter in filters where filter.group == .ads {
            try? FileManager.default.removeItem(at: filtersDir.appendingPathComponent("\(filter.id).json"))
        }
        filters.removeAll { $0.group == .ads }
        if let updated = try? JSONEncoder().encode(filters) {
            try? updated.write(to: metadataFile, options: .atomic)
        }
    }

    @Test("remove drops one source and recomposes the group from the remaining ones")
    func removeRecomposesGroupFromRemainingSources() async throws {
        let pipeline = makePipeline()
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        try await resetAdsGroup(store: store)

        let sourceA = FilterSource(
            filterID: "multi-a", version: "v1", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\"a\\\\.com\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let sourceB = FilterSource(
            filterID: "multi-b", version: "v1", checksumSHA256: "b",
            data: Data("[{\"trigger\":{\"url-filter\":\"b\\\\.com\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let installResult = try await pipeline.install(GroupComposition(group: .ads, sources: [sourceA, sourceB]), reloadStrategy: .deferred)
        #expect(installResult.compiledRuleCount == 2)

        let removeResult = try await pipeline.remove(filterID: "multi-b", group: .ads, reloadStrategy: .deferred)
        #expect(removeResult.compiledRuleCount == 1)

        let compiledDir = try await store.directoryURL(.compiled)
        let compiledData = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))
        let compiledRules = try JSONSerialization.jsonObject(with: compiledData) as? [[String: Any]]
        #expect(compiledRules?.count == 1)

        let installedData = try await store.read("installed_filters.json", in: .metadata)
        let installed = try JSONDecoder().decode([InstalledFilter].self, from: installedData)
        #expect(installed.map(\.id).sorted() == ["multi-a"])

        // Regression: the remaining source's ruleCount/lastUpdated must reflect the fresh,
        // post-removal, group-level compiled count (1) — NOT the stale count from when it was
        // installed alongside multi-b (2). `remove()` calls `installGroup` with
        // `upsertingFilterEntries: []`, so this only passes if `installGroup` refreshes
        // remaining same-group entries even when they aren't in the upsert list.
        #expect(installed.first(where: { $0.id == "multi-a" })?.ruleCount == 1)

        try await resetAdsGroup(store: store)
    }

    @Test("remove of the last source in a group writes a valid empty rule array")
    func removeLastSourceProducesEmptyRules() async throws {
        let pipeline = makePipeline()
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        try await resetAdsGroup(store: store)

        let source = FilterSource(
            filterID: "solo", version: "v1", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [source]), reloadStrategy: .deferred)

        _ = try await pipeline.remove(filterID: "solo", group: .ads, reloadStrategy: .deferred)

        let compiledDir = try await store.directoryURL(.compiled)
        let compiledData = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))
        let compiledRules = try JSONSerialization.jsonObject(with: compiledData) as? [Any]
        #expect(compiledRules?.isEmpty == true)

        let installedData = try await store.read("installed_filters.json", in: .metadata)
        let installed = try JSONDecoder().decode([InstalledFilter].self, from: installedData)
        #expect(installed.isEmpty)

        try await resetAdsGroup(store: store)
    }

    @Test("remove then reinstall the same filter reproduces identical compiled output")
    func removeThenReinstallSameFilterIsDeterministic() async throws {
        let pipeline = makePipeline()
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        try await resetAdsGroup(store: store)
        let payload = Data("[{\"trigger\":{\"url-filter\":\"deterministic\\\\.com\"},\"action\":{\"type\":\"block\"}}]".utf8)
        let source = FilterSource(filterID: "det-test", version: "v1", checksumSHA256: "a", data: payload)

        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [source]), reloadStrategy: .deferred)
        let compiledDir = try await store.directoryURL(.compiled)
        let firstCompiled = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))

        _ = try await pipeline.remove(filterID: "det-test", group: .ads, reloadStrategy: .deferred)
        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [source]), reloadStrategy: .deferred)
        let secondCompiled = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))

        #expect(firstCompiled == secondCompiled)

        try await resetAdsGroup(store: store)
    }
}
