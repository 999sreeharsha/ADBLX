import Foundation

/// Output of the compilation stage: raw Safari content-blocker JSON, ready to be partitioned
/// and written into the App Group container. `rawJSON` is the actual Safari rule payload —
/// treat it as opaque data here; nothing in Models/ inspects or logs its contents.
struct CompiledRuleSet: Codable, Equatable {
    var sourceFilterID: String
    var rawJSON: Data
    var ruleCount: Int
    var statistics: RuleStatistics
}
