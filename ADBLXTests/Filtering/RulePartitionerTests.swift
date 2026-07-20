import Testing
import Foundation
@testable import ADBLX

@Suite("GroupPartitioner")
struct GroupPartitionerTests {
    private let identifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    private func ruleSet(group: FilterGroup, ruleCount: Int) -> CompiledRuleSet {
        CompiledRuleSet(
            group: group,
            rawJSON: Data("[]".utf8),
            ruleCount: ruleCount,
            statistics: RuleStatistics(
                compileDuration: 0.01, rulesLoaded: ruleCount, duplicatesRemoved: 0,
                unsupportedRuleCount: 0, memoryEstimateBytes: 2048, lastUpdated: Date()
            )
        )
    }

    @Test("routes .ads to the Ads extension identifier")
    func routesAds() async throws {
        let partitioner = GroupPartitioner(extensionIdentifiers: identifiers)
        let partition = try await partitioner.partition(ruleSet(group: .ads, ruleCount: 70), group: .ads)

        #expect(partition.group == .ads)
        #expect(partition.extensionIdentifier == "com.ADBLX.ADBLX.AdsBlocker")
        #expect(partition.ruleCount == 70)
    }

    @Test("routes each of the four groups to its own extension identifier", arguments: [
        (FilterGroup.ads, "com.ADBLX.ADBLX.AdsBlocker"),
        (FilterGroup.privacy, "com.ADBLX.ADBLX.PrivacyBlocker"),
        (FilterGroup.annoyances, "com.ADBLX.ADBLX.AnnoyancesBlocker"),
        (FilterGroup.regional, "com.ADBLX.ADBLX.RegionalBlocker"),
    ])
    func routesEveryGroup(group: FilterGroup, expectedIdentifier: String) async throws {
        let partitioner = GroupPartitioner(extensionIdentifiers: identifiers)
        let partition = try await partitioner.partition(ruleSet(group: group, ruleCount: 10), group: group)

        #expect(partition.extensionIdentifier == expectedIdentifier)
    }

    @Test("throws when rule count exceeds the per-extension budget")
    func throwsWhenOverBudget() async {
        let partitioner = GroupPartitioner(extensionIdentifiers: identifiers)
        await #expect(throws: RulePartitionerError.self) {
            _ = try await partitioner.partition(ruleSet(group: .ads, ruleCount: 150_001), group: .ads)
        }
    }
}
