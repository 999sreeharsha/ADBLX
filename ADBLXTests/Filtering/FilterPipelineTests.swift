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
}
