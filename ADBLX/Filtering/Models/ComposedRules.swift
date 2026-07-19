import Foundation

/// Output of `CompositionService`: every source in a `GroupComposition` merged into one
/// rule set, ready for `RuleCompiler.compile(source:group:)`. `sourceCount`/`ruleCount`
/// exist so callers can log/report composition size without re-decoding `data`.
struct ComposedRules: Equatable {
    let group: FilterGroup
    let data: Data
    let sourceCount: Int
    let ruleCount: Int
}
