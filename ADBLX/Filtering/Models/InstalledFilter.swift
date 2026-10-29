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
    /// Whether this filter is gated behind Premium. `nil` = a legacy record written before
    /// this field existed; `PremiumEntitlementReconciler` resolves it from the cached
    /// manifest, then the bundled premium catalog, and persists the answer.
    var premium: Bool?

    init(
        id: String,
        group: FilterGroup,
        installedVersion: String,
        checksumSHA256: String,
        lastUpdated: Date,
        ruleCount: Int,
        premium: Bool? = nil
    ) {
        self.id = id
        self.group = group
        self.installedVersion = installedVersion
        self.checksumSHA256 = checksumSHA256
        self.lastUpdated = lastUpdated
        self.ruleCount = ruleCount
        self.premium = premium
    }
}
