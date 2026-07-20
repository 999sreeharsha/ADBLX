import Foundation

/// Total mapping from `FilterGroup` to its Content Blocker extension's bundle identifier.
/// Every field is required and non-optional, and `subscript` is an exhaustive `switch` —
/// an unmapped group is a compile-time impossibility (a new `FilterGroup` case would fail
/// to compile here until handled), not a runtime `.unmappedGroup`-style error case.
struct GroupExtensionIdentifiers: Sendable {
    let ads: String
    let privacy: String
    let annoyances: String
    let regional: String

    subscript(_ group: FilterGroup) -> String {
        switch group {
        case .ads: return ads
        case .privacy: return privacy
        case .annoyances: return annoyances
        case .regional: return regional
        }
    }
}

/// Wraps one group's compiled rules for writing, plus which extension they belong to.
///
/// Target: main app ONLY. The requirement is `nonisolated` — see Task 3's (Sprint 1) note on
/// SWIFT_DEFAULT_ACTOR_ISOLATION.
protocol RulePartitioner: Sendable {
    /// A `CompiledRuleSet` corresponds to exactly one group by construction (it came from
    /// one `GroupComposition`), so this returns a single `PartitionedRules`, not an array.
    nonisolated func partition(_ ruleSet: CompiledRuleSet, group: FilterGroup) async throws -> PartitionedRules
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

struct GroupPartitioner: RulePartitioner {
    /// Per PRD §6.1 / Appendix B.1 — 150K compiled rules per extension.
    static let ruleBudgetPerExtension = 150_000

    let extensionIdentifiers: GroupExtensionIdentifiers

    nonisolated func partition(_ ruleSet: CompiledRuleSet, group: FilterGroup) async throws -> PartitionedRules {
        guard ruleSet.ruleCount <= Self.ruleBudgetPerExtension else {
            throw RulePartitionerError.ruleBudgetExceeded(
                group: group,
                count: ruleSet.ruleCount,
                limit: Self.ruleBudgetPerExtension
            )
        }
        return PartitionedRules(
            extensionIdentifier: extensionIdentifiers[group],
            group: group,
            json: ruleSet.rawJSON,
            ruleCount: ruleSet.ruleCount
        )
    }
}
