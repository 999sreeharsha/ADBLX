import Foundation

/// Tracks what's actually on disk right now, as opposed to `FilterManifest` which describes
/// what's available. Persisted as `installed_filters.json` (FilterStore/Metadata).
struct InstalledFilter: Codable, Equatable, Identifiable {
    var id: String
    var group: FilterGroup
    var installedVersion: String
    var checksumSHA256: String
    var lastUpdated: Date
    /// Compiled rule count of the installed `group`'s artifact, not this filter's own
    /// contribution — composition discards per-source counts, so every source in a
    /// multi-source group reports the same group-level total.
    var ruleCount: Int
}
