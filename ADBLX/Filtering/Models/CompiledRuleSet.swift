import Foundation

/// Output of the compilation stage: raw Safari content-blocker JSON, ready to be partitioned
/// and written into the App Group container. `rawJSON` is the actual Safari rule payload —
/// treat it as opaque data here; nothing in Models/ inspects or logs its contents.
///
/// `group`, not a filter id: a `CompiledRuleSet` is the result of compiling one
/// `GroupComposition`, which may span multiple source filters — there is no single
/// "source filter" left to name once composition has happened. Per-filter identity lives
/// in `InstalledFilter`, one entry per source, not here.
struct CompiledRuleSet: Codable, Equatable {
    var group: FilterGroup
    var rawJSON: Data
    var ruleCount: Int
    var statistics: RuleStatistics
}
