import Testing
import Foundation
@testable import ADBLX

@Suite("Filtering Models")
struct FilteringModelsTests {
    @Test("RuleStatistics round-trips through JSON")
    func ruleStatisticsRoundTrip() throws {
        let original = RuleStatistics(
            compileDuration: 1.23,
            rulesLoaded: 70,
            duplicatesRemoved: 2,
            unsupportedRuleCount: 1,
            memoryEstimateBytes: 4096,
            lastUpdated: Date(timeIntervalSince1970: 1_752_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuleStatistics.self, from: data)
        #expect(decoded == original)
    }

    @Test("CompiledRuleSet round-trips through JSON")
    func compiledRuleSetRoundTrip() throws {
        let stats = RuleStatistics(
            compileDuration: 0.5, rulesLoaded: 3, duplicatesRemoved: 0,
            unsupportedRuleCount: 0, memoryEstimateBytes: 128,
            lastUpdated: Date(timeIntervalSince1970: 1_752_000_000)
        )
        let original = CompiledRuleSet(
            sourceFilterID: "ads-bundled", rawJSON: Data("[]".utf8), ruleCount: 3,
            statistics: stats
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompiledRuleSet.self, from: data)
        #expect(decoded == original)
    }

    @Test("FilterManifest round-trips through JSON")
    func filterManifestRoundTrip() throws {
        let entry = FilterManifest.Entry(
            id: "ads-bundled", name: "Ads", group: .ads,
            sourceURL: URL(string: "https://example.com/ads.txt")!,
            version: "2026-07-17", checksumSHA256: "abc123", ruleCount: 70,
            enabledByDefault: true, premium: false
        )
        let original = FilterManifest(manifestVersion: "1", entries: [entry])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FilterManifest.self, from: data)
        #expect(decoded == original)
    }

    @Test("FilterMetadata round-trips through JSON")
    func filterMetadataRoundTrip() throws {
        let original = FilterMetadata(
            id: "ads-bundled", displayName: "Ads", group: .ads, version: "2026-07-17",
            ruleCount: 70, premium: false, lastCompileDuration: 0.5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FilterMetadata.self, from: data)
        #expect(decoded == original)
    }

    @Test("InstalledFilter round-trips through JSON")
    func installedFilterRoundTrip() throws {
        let original = InstalledFilter(
            id: "ads-bundled", group: .ads, installedVersion: "bundled-snapshot",
            checksumSHA256: "abc123", lastUpdated: Date(timeIntervalSince1970: 1_752_000_000),
            ruleCount: 70
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InstalledFilter.self, from: data)
        #expect(decoded == original)
    }

    @Test("FilterSource equality is field-based")
    func filterSourceEquality() {
        let a = FilterSource(filterID: "easylist", version: "2026-07-19", checksumSHA256: "abc", data: Data("[]".utf8))
        let b = FilterSource(filterID: "easylist", version: "2026-07-19", checksumSHA256: "abc", data: Data("[]".utf8))
        let c = FilterSource(filterID: "peter-lowe", version: "2026-07-19", checksumSHA256: "abc", data: Data("[]".utf8))
        #expect(a == b)
        #expect(a != c)
    }

    @Test("GroupComposition preserves source order and is not equal under reordering")
    func groupCompositionPreservesOrder() {
        let easyList = FilterSource(filterID: "easylist", version: "v1", checksumSHA256: "a", data: Data("[]".utf8))
        let peterLowe = FilterSource(filterID: "peter-lowe", version: "v1", checksumSHA256: "b", data: Data("[]".utf8))

        let ordered = GroupComposition(group: .ads, sources: [easyList, peterLowe])
        let reordered = GroupComposition(group: .ads, sources: [peterLowe, easyList])

        #expect(ordered.sources.map(\.filterID) == ["easylist", "peter-lowe"])
        #expect(ordered != reordered)
    }

    @Test("ComposedRules equality is field-based")
    func composedRulesEquality() {
        let a = ComposedRules(group: .ads, data: Data("[]".utf8), sourceCount: 2, ruleCount: 10)
        let b = ComposedRules(group: .ads, data: Data("[]".utf8), sourceCount: 2, ruleCount: 10)
        let c = ComposedRules(group: .ads, data: Data("[]".utf8), sourceCount: 2, ruleCount: 11)
        #expect(a == b)
        #expect(a != c)
    }
}
