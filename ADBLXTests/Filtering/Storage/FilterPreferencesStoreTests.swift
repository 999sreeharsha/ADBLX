// ADBLXTests/Filtering/Storage/FilterPreferencesStoreTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("FilterPreferencesStore", .serialized)
struct FilterPreferencesStoreTests {
    private func makeStore() async throws -> FilterStore {
        let store = FilterStore.temporary()
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("filter_preferences.json"))
        return store
    }

    @Test("first load with no existing file writes and returns explicit defaults for all four categories")
    func firstLoadWritesExplicitDefaults() async throws {
        let filterStore = try await makeStore()
        let preferencesStore = FilterPreferencesStore(store: filterStore)

        let preferences = await preferencesStore.load()

        #expect(preferences.categories[.ads] == true)
        #expect(preferences.categories[.privacy] == true)
        #expect(preferences.categories[.annoyances] == true)
        #expect(preferences.categories[.regional] == true)
        #expect(preferences.filterLists.isEmpty)

        // Defaults must actually be persisted, not just returned in-memory —
        // a second store instance reading the same file should see the same values.
        let data = try await filterStore.read("filter_preferences.json", in: .metadata)
        let decoded = try JSONDecoder().decode(FilterPreferences.self, from: data)
        #expect(decoded.categories[.ads] == true)
    }

    @Test("setCategory persists across a fresh store instance")
    func setCategoryPersists() async throws {
        let filterStore = try await makeStore()
        let preferencesStore = FilterPreferencesStore(store: filterStore)
        _ = await preferencesStore.load()

        await preferencesStore.setCategory(.annoyances, enabled: false)

        let freshInstance = FilterPreferencesStore(store: filterStore)
        let preferences = await freshInstance.load()
        #expect(preferences.categories[.annoyances] == false)
        #expect(preferences.categories[.ads] == true)
    }

    @Test("setFilterList adds or updates an entry and persists it")
    func setFilterListPersists() async throws {
        let filterStore = try await makeStore()
        let preferencesStore = FilterPreferencesStore(store: filterStore)
        _ = await preferencesStore.load()

        await preferencesStore.setFilterList("easylist", enabled: false)

        let freshInstance = FilterPreferencesStore(store: filterStore)
        let preferences = await freshInstance.load()
        #expect(preferences.filterLists["easylist"] == false)
    }
}
