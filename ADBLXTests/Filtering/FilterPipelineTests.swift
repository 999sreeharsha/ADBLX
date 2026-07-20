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

        #expect(result.filterID == "ads-bundled")
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

    @Test("throws when the source fails validation")
    func throwsOnInvalidSource() async {
        let pipeline = makePipeline()
        await #expect(throws: FilterValidator.ValidationError.self) {
            _ = try await pipeline.install(filterID: "bad", source: Data())
        }
    }

    @Test("reloadStrategy .deferred skips the reload call and returns empty reloadResults")
    func deferredReloadSkipsReloadCall() async throws {
        let pipeline = makePipeline()
        let source = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        let result = try await pipeline.install(filterID: "deferred-test", source: source, reloadStrategy: .deferred)

        #expect(result.reloadResults.isEmpty)
    }

    @Test("installing a second filter after a first accumulates both in installed_filters.json")
    func installingSecondFilterAccumulatesMetadata() async throws {
        let pipeline = makePipeline()
        let source = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        _ = try await pipeline.install(filterID: "filter-a", source: source, reloadStrategy: .deferred)
        _ = try await pipeline.install(filterID: "filter-b", source: source, reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(Set(filters.map(\.id)).isSuperset(of: ["filter-a", "filter-b"]))
    }

    @Test("re-installing the same filterID replaces its entry instead of duplicating it")
    func reinstallingSameFilterIDReplacesEntry() async throws {
        let pipeline = makePipeline()
        let source = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        _ = try await pipeline.install(filterID: "filter-a", source: source, reloadStrategy: .deferred)
        _ = try await pipeline.install(filterID: "filter-a", source: source, reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(filters.filter { $0.id == "filter-a" }.count == 1)
    }

    @Test("install(version:) records the passed version, not the bundled-snapshot default")
    func installRecordsPassedVersion() async throws {
        let pipeline = makePipeline()
        let source = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        _ = try await pipeline.install(filterID: "filter-versioned", source: source, version: "2026-07-18", reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(filters.first(where: { $0.id == "filter-versioned" })?.installedVersion == "2026-07-18")
    }
}
