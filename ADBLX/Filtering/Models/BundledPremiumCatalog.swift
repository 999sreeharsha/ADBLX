import Foundation

/// What the app ships knowing is Premium-gated, independent of any fetched manifest.
/// Used to classify legacy `InstalledFilter` records (no `premium` flag) when no cached
/// manifest is available, and as the offline baseline for what an entitled user should have.
enum BundledPremiumCatalog {
    static let annoyancesFilterID = "fanboy-annoyances"
    static let shieldFixesFilterID = "shield-fixes"

    struct Entry: Equatable {
        let filterID: String
        let group: FilterGroup
    }

    /// Premium lists whose payload is bundled and can be installed with no network.
    static let bundledEntries: [Entry] = [
        Entry(filterID: annoyancesFilterID, group: .annoyances),
        Entry(filterID: shieldFixesFilterID, group: .annoyances)
    ]

    static func isPremium(filterID: String) -> Bool {
        bundledEntries.contains { $0.filterID == filterID }
    }
}
