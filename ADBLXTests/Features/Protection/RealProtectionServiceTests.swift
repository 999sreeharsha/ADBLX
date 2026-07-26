// ADBLXTests/Features/Protection/RealProtectionServiceTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("RealProtectionService", .serialized)
struct RealProtectionServiceTests {
    private func makeStores() async throws -> (FilterStore, FilterPreferencesStore) {
        let filterStore = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("filter_preferences.json"))
        return (filterStore, FilterPreferencesStore(store: filterStore))
    }

    @Test("always returns all four categories, even with nothing installed")
    func alwaysReturnsAllFourCategories() async throws {
        let (filterStore, preferencesStore) = try await makeStores()
        let service = RealProtectionService(store: filterStore, preferencesStore: preferencesStore)

        let status = await service.fetchStatus()

        #expect(status.categories.count == 4)
        #expect(Set(status.categories.map(\.id)) == Set(FilterCategoryID.allCases))
        for category in status.categories {
            #expect(category.ruleCount == 0)
            #expect(category.isEnabled == true)  // FilterPreferences.defaults
        }
        #expect(status.filterLists.isEmpty)
    }

    @Test("category ruleCount sums once per unique group, not per InstalledFilter entry")
    func ruleCountSumsOncePerGroup() async throws {
        let (filterStore, preferencesStore) = try await makeStores()
        let filters = [
            InstalledFilter(
                id: "easylist", group: .ads, installedVersion: "1", checksumSHA256: "a",
                lastUpdated: Date(), ruleCount: 62_000
            ),
            InstalledFilter(
                id: "easylist-extra", group: .ads, installedVersion: "1", checksumSHA256: "b",
                lastUpdated: Date(), ruleCount: 62_000
            ),
        ]
        let data = try JSONEncoder().encode(filters)
        try await filterStore.writeMetadata(data, filename: "installed_filters.json")

        let service = RealProtectionService(store: filterStore, preferencesStore: preferencesStore)
        let status = await service.fetchStatus()

        let adsCategory = status.categories.first { $0.id == .ads }
        #expect(adsCategory?.ruleCount == 62_000)
        #expect(status.filterLists.count == 2)
    }

    @Test("setCategory writes through to FilterPreferencesStore and is reflected on next fetch")
    func setCategoryWritesThrough() async throws {
        let (filterStore, preferencesStore) = try await makeStores()
        let service = RealProtectionService(store: filterStore, preferencesStore: preferencesStore)
        _ = await service.fetchStatus()

        await service.setCategory(.privacy, enabled: false)

        let status = await service.fetchStatus()
        let privacyCategory = status.categories.first { $0.id == .privacy }
        #expect(privacyCategory?.isEnabled == false)
    }

    @Test("setFilterList writes through to FilterPreferencesStore and is reflected on next fetch")
    func setFilterListWritesThrough() async throws {
        let (filterStore, preferencesStore) = try await makeStores()
        let filters = [
            InstalledFilter(
                id: "easylist", group: .ads, installedVersion: "1", checksumSHA256: "a",
                lastUpdated: Date(), ruleCount: 62_000
            ),
        ]
        let data = try JSONEncoder().encode(filters)
        try await filterStore.writeMetadata(data, filename: "installed_filters.json")
        let service = RealProtectionService(store: filterStore, preferencesStore: preferencesStore)
        _ = await service.fetchStatus()

        await service.setFilterList("easylist", enabled: false)

        let status = await service.fetchStatus()
        #expect(status.filterLists.first?.isEnabled == false)
    }
}
