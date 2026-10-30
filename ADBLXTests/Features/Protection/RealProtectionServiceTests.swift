// ADBLXTests/Features/Protection/RealProtectionServiceTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("RealProtectionService", .serialized)
struct RealProtectionServiceTests {
    private func makeStores() async throws -> (FilterStore, FilterPreferencesStore) {
        let filterStore = FilterStore.temporary()
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
            )
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
            )
        ]
        let data = try JSONEncoder().encode(filters)
        try await filterStore.writeMetadata(data, filename: "installed_filters.json")
        let service = RealProtectionService(store: filterStore, preferencesStore: preferencesStore)
        _ = await service.fetchStatus()

        await service.setFilterList("easylist", enabled: false)

        let status = await service.fetchStatus()
        #expect(status.filterLists.first?.isEnabled == false)
    }

    @Test("masterState aggregates correctly based on participating blockers and Settings states")
    func masterStateAggregation() async throws {
        let (filterStore, preferencesStore) = try await makeStores()
        let mockProvider = MockContentBlockerStateProvider(states: [
            "com.ADBLX.ADBLX.AdsBlocker": .enabled,
            "com.ADBLX.ADBLX.PrivacyBlocker": .disabled
        ])

        let descriptors = [
            ContentBlockerDescriptor(
                category: .ads,
                extensionIdentifier: "com.ADBLX.ADBLX.AdsBlocker",
                participatesInProtectionStatus: true
            ),
            ContentBlockerDescriptor(
                category: .privacy,
                extensionIdentifier: "com.ADBLX.ADBLX.PrivacyBlocker",
                participatesInProtectionStatus: true
            ),
            ContentBlockerDescriptor(
                category: .annoyances,
                extensionIdentifier: "com.ADBLX.ADBLX.AnnoyancesBlocker",
                participatesInProtectionStatus: false
            ),
            ContentBlockerDescriptor(
                category: .regional,
                extensionIdentifier: "com.ADBLX.ADBLX.RegionalBlocker",
                participatesInProtectionStatus: false
            )
        ]

        let service = RealProtectionService(
            store: filterStore,
            preferencesStore: preferencesStore,
            stateProvider: mockProvider,
            descriptors: descriptors
        )

        // Case 1: Ads enabled, Privacy disabled in Settings -> partiallyActive
        var status = await service.fetchStatus()
        #expect(status.masterState == .partiallyActive)

        // Case 2: Privacy is also enabled in Settings -> active
        await mockProvider.setState(.enabled, for: "com.ADBLX.ADBLX.PrivacyBlocker")
        status = await service.fetchStatus()
        #expect(status.masterState == .active)

        // Case 3: Both disabled in Settings -> disabledInSettings
        await mockProvider.setState(.disabled, for: "com.ADBLX.ADBLX.AdsBlocker")
        await mockProvider.setState(.disabled, for: "com.ADBLX.ADBLX.PrivacyBlocker")
        status = await service.fetchStatus()
        #expect(status.masterState == .disabledInSettings)

        // Case 4: User disables both in app preferences -> disabledByUser
        await service.setCategory(.ads, enabled: false)
        await service.setCategory(.privacy, enabled: false)
        status = await service.fetchStatus()
        #expect(status.masterState == .disabledByUser)

        // Case 5: One participating is unavailable -> unavailable
        await service.setCategory(.ads, enabled: true)
        await mockProvider.setState(.unavailable("Disk Error"), for: "com.ADBLX.ADBLX.AdsBlocker")
        status = await service.fetchStatus()
        #expect(status.masterState == .unavailable)
    }

    @Test("Settings state never pollutes or mutates FilterPreferencesStore")
    func settingsStateDoesNotOverwritePreferences() async throws {
        let (filterStore, preferencesStore) = try await makeStores()
        let mockProvider = MockContentBlockerStateProvider(states: [
            "com.ADBLX.ADBLX.AdsBlocker": .disabled
        ])

        let service = RealProtectionService(
            store: filterStore,
            preferencesStore: preferencesStore,
            stateProvider: mockProvider
        )

        // Extension is disabled in Settings, but preference was default true
        let status = await service.fetchStatus()
        let adsCategory = status.categories.first { $0.id == .ads }
        #expect(adsCategory?.preferenceEnabled == true)
        #expect(adsCategory?.extensionSettingsState == .disabled)
        #expect(adsCategory?.status == .disabledInSettings)

        // Verify direct stored preferences did NOT change
        let prefs = await preferencesStore.load()
        #expect(prefs.categories[.ads] == true)
    }
}
