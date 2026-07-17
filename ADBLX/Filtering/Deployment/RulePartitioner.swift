import Foundation

/// Splits compiled rules across the 4 Content Blocker extensions, respecting each
/// extension's 150K-rule budget.
///
/// Sprint 1 scope: passthrough for the Ads extension only. Privacy/Annoyances/Regional
/// extensions continue to ship their existing Sprint 0 bundled-JSON copy unchanged this
/// sprint — this is a deliberate scope line, not a regression against FR-01.
///
/// Target: main app ONLY. The requirement is `nonisolated` — see Task 3's note on
/// SWIFT_DEFAULT_ACTOR_ISOLATION.
protocol RulePartitioner: Sendable {
    nonisolated func partition(_ ruleSet: CompiledRuleSet) async throws -> [PartitionedRules]
}

struct PartitionedRules {
    var extensionIdentifier: String
    var group: FilterGroup
    var json: Data
    var ruleCount: Int
}

enum RulePartitionerError: Error {
    case ruleBudgetExceeded(group: FilterGroup, count: Int, limit: Int)
}

struct PassthroughAdsPartitioner: RulePartitioner {
    /// Per PRD §6.1 / Appendix B.1 — 150K compiled rules per extension.
    static let ruleBudgetPerExtension = 150_000

    let adsExtensionIdentifier: String

    nonisolated func partition(_ ruleSet: CompiledRuleSet) async throws -> [PartitionedRules] {
        guard ruleSet.ruleCount <= Self.ruleBudgetPerExtension else {
            throw RulePartitionerError.ruleBudgetExceeded(
                group: .ads,
                count: ruleSet.ruleCount,
                limit: Self.ruleBudgetPerExtension
            )
        }
        return [
            PartitionedRules(
                extensionIdentifier: adsExtensionIdentifier,
                group: .ads,
                json: ruleSet.rawJSON,
                ruleCount: ruleSet.ruleCount
            )
        ]
    }
}
