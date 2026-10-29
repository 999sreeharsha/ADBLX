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

    private func makeIsolatedPipeline() -> (pipeline: FilterPipeline, store: FilterStore, tempDir: URL) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FilterPipelineTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let store = FilterStore(overrideBaseURL: temp)
        let pipeline = FilterPipeline(
            validator: FilterValidator(),
            compiler: NativeRuleCompilerAdapter(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store,
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator()
        )
        return (pipeline, store, temp)
    }

    @Test("installs bundled snapshots end-to-end and returns populated PipelineResults")
    func installsBundledSnapshotEndToEnd() async throws {
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let results = try await pipeline.installBundledSnapshotIfNeeded()

        #expect(!results.isEmpty)
        let adsResult = try #require(results.first(where: { $0.group == .ads }))
        #expect(adsResult.compiledRuleCount > 0)
        #expect(adsResult.installedRuleCount <= GroupPartitioner.ruleBudgetPerExtension)
        #expect(adsResult.reloadResults.count >= 1)
        #expect(adsResult.reloadResults[0].extensionIdentifier == "com.ADBLX.ADBLX.AdsBlocker")

        let compiledDir = try await store.directoryURL(.compiled)
        let writtenData = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))
        let writtenRules = try JSONSerialization.jsonObject(with: writtenData) as? [Any]
        #expect(writtenRules?.count == adsResult.compiledRuleCount)

        let metadataDir = try await store.directoryURL(.metadata)
        #expect(FileManager.default.fileExists(atPath: metadataDir.appendingPathComponent("installed_filters.json").path))
        #expect(FileManager.default.fileExists(atPath: metadataDir.appendingPathComponent("statistics.json").path))
    }

    @Test("bundled snapshot is free-only unless premium is requested")
    func bundledSnapshotIsFreeOnlyByDefault() async throws {
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let results = try await pipeline.installBundledSnapshotIfNeeded()
        #expect(results.contains { $0.group == .ads })
        #expect(results.contains { $0.group == .privacy })
        #expect(!results.contains { $0.group == .annoyances })
        #expect(!results.contains { $0.group == .regional })

        let compiledDir = try await store.directoryURL(.compiled)
        #expect(!FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent("Annoyances.json").path))
        #expect(!FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent("Regional.json").path))

        let installed = try JSONDecoder().decode(
            [InstalledFilter].self, from: try await store.read("installed_filters.json", in: .metadata)
        )
        #expect(installed.allSatisfy { $0.group == .ads || $0.group == .privacy })
        #expect(installed.allSatisfy { $0.premium == false || $0.premium == nil })
    }

    @Test("entitled bundled snapshot additionally installs Annoyances, flagged premium")
    func bundledSnapshotIncludesPremiumWhenEntitled() async throws {
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let results = try await pipeline.installBundledSnapshotIfNeeded(includePremium: true)
        #expect(results.contains { $0.group == .annoyances })

        let installed = try JSONDecoder().decode(
            [InstalledFilter].self, from: try await store.read("installed_filters.json", in: .metadata)
        )
        let annoyances = try #require(installed.first { $0.id == "fanboy-annoyances" })
        #expect(annoyances.group == .annoyances)
        #expect(annoyances.premium == true)
    }

    @Test("throws when a source fails validation")
    func throwsWhenSourceFailsValidation() async throws {
        let (pipeline, _, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let invalidSource = FilterSource(filterID: "invalid", version: "v1", checksumSHA256: "a", data: Data())
        let composition = GroupComposition(group: .ads, sources: [invalidSource])

        await #expect(throws: FilterValidator.ValidationError.empty) {
            _ = try await pipeline.install(composition)
        }
    }

    @Test("throws when a source exceeds the rule budget in partitioning")
    func throwsWhenRuleBudgetExceeded() async throws {
        let (pipeline, _, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let hugeArray = Array(repeating: ["trigger": ["url-filter": ".*"], "action": ["type": "block"]], count: 150_001)
        let hugeData = try JSONSerialization.data(withJSONObject: hugeArray)
        let hugeSource = FilterSource(filterID: "huge", version: "v1", checksumSHA256: "a", data: hugeData)
        let composition = GroupComposition(group: .ads, sources: [hugeSource])

        await #expect(throws: RulePartitionerError.self) {
            _ = try await pipeline.install(composition)
        }
    }

    @Test("rolls back disk state to pre-install snapshot if partitioning fails")
    func rollsBackOnPartitioningFailure() async throws {
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let compiledDir = try await store.directoryURL(.compiled)
        let priorFile = compiledDir.appendingPathComponent("Ads.json")
        try Data("[\"prior-stable\"]".utf8).write(to: priorFile, options: .atomic)

        let hugeArray = Array(repeating: ["trigger": ["url-filter": ".*"], "action": ["type": "block"]], count: 150_001)
        let hugeData = try JSONSerialization.data(withJSONObject: hugeArray)
        let hugeSource = FilterSource(filterID: "huge", version: "v1", checksumSHA256: "a", data: hugeData)
        let composition = GroupComposition(group: .ads, sources: [hugeSource])

        do {
            _ = try await pipeline.install(composition)
        } catch {
            // Expected
        }

        #expect(try Data(contentsOf: priorFile) == Data("[\"prior-stable\"]".utf8))
    }

    @Test("deferred reload strategy returns empty reloadResults and skips extension reload")
    func deferredReloadStrategyReturnsEmptyResults() async throws {
        let (pipeline, _, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let payload = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        let source = FilterSource(filterID: "test", version: "v1", checksumSHA256: "a", data: payload)
        let composition = GroupComposition(group: .ads, sources: [source])

        let result = try await pipeline.install(composition, reloadStrategy: .deferred)

        #expect(result.reloadResults.isEmpty)
    }

    @Test("installing the same composition twice produces byte-identical Compiled/<Group>.json output")
    func installingTwiceIsDeterministic() async throws {
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let payload = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        let source = FilterSource(filterID: "det-test", version: "v1", checksumSHA256: "a", data: payload)
        let composition = GroupComposition(group: .ads, sources: [source])

        _ = try await pipeline.install(composition, reloadStrategy: .deferred)
        let compiledDir = try await store.directoryURL(.compiled)
        let firstCompiled = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))

        _ = try await pipeline.install(composition, reloadStrategy: .deferred)
        let secondCompiled = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))

        #expect(firstCompiled == secondCompiled)
    }

    @Test("install with multiple sources composes all rules, writes Compiled/<Group>.json, and merges installed_filters.json")
    func installMultipleSourcesComposesAndMerges() async throws {
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let source1 = FilterSource(
            filterID: "easylist", version: "2026.04.18", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\"a.*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let source2 = FilterSource(
            filterID: "peter-lowe", version: "2026.04.18", checksumSHA256: "b",
            data: Data("[{\"trigger\":{\"url-filter\":\"b.*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let composition = GroupComposition(group: .ads, sources: [source1, source2])

        let result = try await pipeline.install(composition, reloadStrategy: .deferred)

        #expect(result.group == .ads)
        #expect(result.compiledRuleCount == 2)
        #expect(result.installedRuleCount == 2)

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
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let payload = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        let source = FilterSource(filterID: "persist-test", version: "v1", checksumSHA256: "a", data: payload)
        let composition = GroupComposition(group: .ads, sources: [source])

        _ = try await pipeline.install(composition, reloadStrategy: .deferred)

        let readBack = try await store.readFilterPayload(filterID: "persist-test")
        #expect(readBack == payload)
    }

    @Test("remove drops one source and recomposes the group from the remaining ones")
    func removeRecomposesGroupFromRemainingSources() async throws {
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

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
        #expect(installed.first(where: { $0.id == "multi-a" })?.ruleCount == 1)
    }

    @Test("remove of the last source in a group writes a valid empty rule array")
    func removeLastSourceProducesEmptyRules() async throws {
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

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
    }

    @Test("remove then reinstall the same filter reproduces identical compiled output")
    func removeThenReinstallSameFilterIsDeterministic() async throws {
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let payload = Data("[{\"trigger\":{\"url-filter\":\"deterministic\\\\.com\"},\"action\":{\"type\":\"block\"}}]".utf8)
        let source = FilterSource(filterID: "det-test", version: "v1", checksumSHA256: "a", data: payload)

        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [source]), reloadStrategy: .deferred)
        let compiledDir = try await store.directoryURL(.compiled)
        let firstCompiled = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))

        _ = try await pipeline.remove(filterID: "det-test", group: .ads, reloadStrategy: .deferred)
        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [source]), reloadStrategy: .deferred)
        let secondCompiled = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))

        #expect(firstCompiled == secondCompiled)
    }

    @Test("each compiled group in bundled snapshot respects 150k rule budget and produces valid JSON")
    func bundledSnapshotAdheresToBudget() async throws {
        let (pipeline, store, temp) = makeIsolatedPipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        let results = try await pipeline.installBundledSnapshotIfNeeded()
        let compiledDir = try await store.directoryURL(.compiled)

        for result in results {
            #expect(result.compiledRuleCount > 0)
            #expect(result.compiledRuleCount <= GroupPartitioner.ruleBudgetPerExtension)
            #expect(result.installedRuleCount == result.compiledRuleCount)

            let filename = "\(result.group.rawValue.capitalized).json"
            let filePath = compiledDir.appendingPathComponent(filename)
            #expect(FileManager.default.fileExists(atPath: filePath.path))

            let data = try Data(contentsOf: filePath)
            let parsed = try JSONSerialization.jsonObject(with: data) as? [Any]
            #expect(parsed?.count == result.compiledRuleCount)
        }
    }
}
