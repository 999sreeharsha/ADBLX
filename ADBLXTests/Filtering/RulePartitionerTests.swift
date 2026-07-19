import Testing
import Foundation
@testable import ADBLX

@Suite("PassthroughAdsPartitioner")
struct PassthroughAdsPartitionerTests {
    @Test("partitions within budget into a single Ads partition")
    func partitionsWithinBudget() async throws {
        let ruleSet = CompiledRuleSet(
            group: .ads,
            rawJSON: Data("[]".utf8),
            ruleCount: 70,
            statistics: RuleStatistics(
                compileDuration: 0.01, rulesLoaded: 70, duplicatesRemoved: 0,
                unsupportedRuleCount: 0, memoryEstimateBytes: 2048, lastUpdated: Date()
            )
        )
        let partitioner = PassthroughAdsPartitioner(adsExtensionIdentifier: "com.ADBLX.ADBLX.AdsBlocker")
        let partitions = try await partitioner.partition(ruleSet)

        #expect(partitions.count == 1)
        #expect(partitions[0].group == .ads)
        #expect(partitions[0].extensionIdentifier == "com.ADBLX.ADBLX.AdsBlocker")
        #expect(partitions[0].ruleCount == 70)
    }

    @Test("throws when rule count exceeds the per-extension budget")
    func throwsWhenOverBudget() async {
        let ruleSet = CompiledRuleSet(
            group: .ads,
            rawJSON: Data("[]".utf8),
            ruleCount: 150_001,
            statistics: RuleStatistics(
                compileDuration: 0.01, rulesLoaded: 150_001, duplicatesRemoved: 0,
                unsupportedRuleCount: 0, memoryEstimateBytes: 2048, lastUpdated: Date()
            )
        )
        let partitioner = PassthroughAdsPartitioner(adsExtensionIdentifier: "com.ADBLX.ADBLX.AdsBlocker")
        await #expect(throws: RulePartitionerError.self) {
            _ = try await partitioner.partition(ruleSet)
        }
    }
}
