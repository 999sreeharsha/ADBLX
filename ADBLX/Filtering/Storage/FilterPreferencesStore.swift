// ADBLX/Filtering/Storage/FilterPreferencesStore.swift
import Foundation

/// Persisted enable/disable state for both protection categories and individual
/// filter lists — one file because both express the same underlying concept
/// ("is this thing on or off"), not two near-identical persistence mechanisms
/// (Sprint 5B design doc).
struct FilterPreferences: Codable, Equatable {
    var categories: [FilterCategoryID: Bool]
    var filterLists: [String: Bool]

    static let defaults = FilterPreferences(
        categories: Dictionary(uniqueKeysWithValues: FilterCategoryID.allCases.map { ($0, true) }),
        filterLists: [:]
    )
}

/// Persists `filter_preferences.json` (FilterStore/Metadata) via the same atomic-write
/// mechanism as `installed_filters.json`. On first load with no existing file, writes
/// and returns explicit defaults rather than treating "missing key" as an implicit
/// default scattered across call sites.
actor FilterPreferencesStore {
    private let store: FilterStore
    private static let filename = "filter_preferences.json"

    init(store: FilterStore) {
        self.store = store
    }

    func load() async -> FilterPreferences {
        guard let data = try? await store.read(Self.filename, in: .metadata),
              let decoded = try? JSONDecoder().decode(FilterPreferences.self, from: data) else {
            let defaults = FilterPreferences.defaults
            try? await save(defaults)
            return defaults
        }
        return decoded
    }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        var preferences = await load()
        preferences.categories[id] = enabled
        try? await save(preferences)
    }

    func setFilterList(_ id: String, enabled: Bool) async {
        var preferences = await load()
        preferences.filterLists[id] = enabled
        try? await save(preferences)
    }

    private func save(_ preferences: FilterPreferences) async throws {
        let data = try JSONEncoder().encode(preferences)
        try await store.writeMetadata(data, filename: Self.filename)
    }
}
