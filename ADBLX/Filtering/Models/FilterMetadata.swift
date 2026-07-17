import Foundation

/// Per-list metadata surfaced in the Filters catalog UI (FR-09).
/// Contains no rule content or domain data — display-facing facts only.
struct FilterMetadata: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var group: FilterGroup
    var version: String
    var ruleCount: Int
    var premium: Bool
    var lastCompileDuration: TimeInterval?
}
