// ADBLXTests/Filtering/FilterPipelineTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("FilterPipeline")
struct FilterPipelineTests {
    private func makePipeline() -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            partitioner: PassthroughAdsPartitioner(adsExtensionIdentifier: "com.ADBLX.ADBLX.AdsBlocker"),
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
}
