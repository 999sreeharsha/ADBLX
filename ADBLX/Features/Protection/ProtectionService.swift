// ADBLX/Features/Protection/ProtectionService.swift
import Foundation

/// UI-facing mirror of the backend's FilterGroup (Filtering/Models/FilterManifest.swift).
/// Deliberately a separate type — the UI layer never imports FilterGroup directly
/// (Sprint 4 spec §5). String raw value + CaseIterable: the canonical, single source
/// of the four-category list — FilterPreferencesStore, RealProtectionService, and
/// AdvancedFilterListsView all iterate FilterCategoryID.allCases rather than each
/// keeping their own hardcoded array (Sprint 5B design doc).
enum FilterCategoryID: String, CaseIterable, Equatable, Codable {
    case ads
    case privacy
    case annoyances
    case regional
}

struct ProtectionCategory: Equatable, Identifiable {
    var id: FilterCategoryID
    let name: String
    let description: String
    var isEnabled: Bool
    let ruleCount: Int
}

/// No ruleCount: CompositionService/FilterPipeline only ever compute a
/// group-level aggregate (docs/gotchas.md) — there is no real per-source
/// count to show at this granularity. The rule-count meter FR-09 calls for
/// lives on ProtectionCategory (Task 1), which is genuinely group-level.
struct FilterListEntry: Equatable, Identifiable {
    var id: String
    let name: String
    let category: FilterCategoryID
    let version: String
    var isEnabled: Bool
    let isPremium: Bool
}

struct ProtectionStatus: Equatable {
    let isSafariExtensionEnabled: Bool
    var categories: [ProtectionCategory]
    var filterLists: [FilterListEntry] = []
}

/// What Safari Protection and Advanced Filter Lists need from the backend.
/// A later sprint's real implementation translates FilterPipeline/FilterManifest
/// state into these screen-shaped types.
protocol ProtectionService: Sendable {
    func fetchStatus() async -> ProtectionStatus
    func setCategory(_ id: FilterCategoryID, enabled: Bool) async
    func setFilterList(_ id: String, enabled: Bool) async
}

actor MockProtectionService: ProtectionService {
    private var status = ProtectionStatus(
        isSafariExtensionEnabled: true,
        categories: [
            ProtectionCategory(
                id: .ads, name: "Ads", description: "Blocks display and video ads", isEnabled: true, ruleCount: 62_000
            ),
            ProtectionCategory(
                id: .privacy, name: "Privacy", description: "Blocks trackers and analytics scripts",
                isEnabled: true, ruleCount: 48_500
            ),
            ProtectionCategory(
                id: .annoyances, name: "Annoyances", description: "Hides cookie banners and popups",
                isEnabled: false, ruleCount: 21_000
            ),
            ProtectionCategory(
                id: .regional, name: "Regional", description: "Extra rules for regional ad networks",
                isEnabled: false, ruleCount: 10_542
            ),
        ],
        filterLists: [
            FilterListEntry(
                id: "easylist", name: "EasyList", category: .ads, version: "2026-07-15",
                isEnabled: true, isPremium: false
            ),
            FilterListEntry(
                id: "easyprivacy", name: "EasyPrivacy", category: .privacy, version: "2026-07-15",
                isEnabled: true, isPremium: false
            ),
            FilterListEntry(
                id: "fanboy-annoyances", name: "Fanboy's Annoyances", category: .annoyances, version: "2026-07-10",
                isEnabled: false, isPremium: true
            ),
            FilterListEntry(
                id: "regional-in", name: "Regional: India", category: .regional, version: "2026-07-01",
                isEnabled: false, isPremium: true
            ),
        ]
    )

    func fetchStatus() async -> ProtectionStatus { status }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        guard let index = status.categories.firstIndex(where: { $0.id == id }) else { return }
        status.categories[index].isEnabled = enabled
    }

    func setFilterList(_ id: String, enabled: Bool) async {
        guard let index = status.filterLists.firstIndex(where: { $0.id == id }) else { return }
        status.filterLists[index].isEnabled = enabled
    }
}

/// Real ProtectionService, backing both Safari Protection and Advanced Filter Lists
/// (they share this one service/ViewModel — Sprint 5B design doc). Categories are
/// always all four (fixed application taxonomy matching GroupExtensionIdentifiers'
/// four content blocker extensions), regardless of install state. Filter lists are
/// built only from genuinely-installed InstalledFilter entries — no blending with
/// the Sprint 1 bundled test fixture manifest.
actor RealProtectionService: ProtectionService {
    private let store: FilterStore
    private let preferencesStore: FilterPreferencesStore

    init(store: FilterStore, preferencesStore: FilterPreferencesStore) {
        self.store = store
        self.preferencesStore = preferencesStore
    }

    func fetchStatus() async -> ProtectionStatus {
        let preferences = await preferencesStore.load()
        let filters = (try? await loadInstalledFilters()) ?? []
        let filtersByGroup = Dictionary(grouping: filters, by: \.group)

        let categories = FilterCategoryID.allCases.map { categoryID in
            let group = filterGroup(for: categoryID)
            let groupFilters = filtersByGroup[group] ?? []
            let uniqueRuleCount = groupFilters.first?.ruleCount ?? 0
            return ProtectionCategory(
                id: categoryID,
                name: categoryDisplayName(categoryID),
                description: categoryDescription(categoryID),
                isEnabled: preferences.categories[categoryID] ?? true,
                ruleCount: uniqueRuleCount
            )
        }

        let filterLists = filters.map { filter in
            FilterListEntry(
                id: filter.id,
                name: filter.id,
                category: categoryID(for: filter.group),
                version: filter.installedVersion,
                isEnabled: preferences.filterLists[filter.id] ?? true,
                isPremium: false
            )
        }

        return ProtectionStatus(
            isSafariExtensionEnabled: true,
            categories: categories,
            filterLists: filterLists
        )
    }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        await preferencesStore.setCategory(id, enabled: enabled)
    }

    func setFilterList(_ id: String, enabled: Bool) async {
        await preferencesStore.setFilterList(id, enabled: enabled)
    }

    private func loadInstalledFilters() async throws -> [InstalledFilter] {
        let data = try await store.read("installed_filters.json", in: .metadata)
        return try JSONDecoder().decode([InstalledFilter].self, from: data)
    }

    private func filterGroup(for categoryID: FilterCategoryID) -> FilterGroup {
        switch categoryID {
        case .ads: return .ads
        case .privacy: return .privacy
        case .annoyances: return .annoyances
        case .regional: return .regional
        }
    }

    private func categoryID(for group: FilterGroup) -> FilterCategoryID {
        switch group {
        case .ads: return .ads
        case .privacy: return .privacy
        case .annoyances: return .annoyances
        case .regional: return .regional
        }
    }

    private func categoryDisplayName(_ id: FilterCategoryID) -> String {
        switch id {
        case .ads: return String(localized: "protection.category.ads")
        case .privacy: return String(localized: "protection.category.privacy")
        case .annoyances: return String(localized: "protection.category.annoyances")
        case .regional: return String(localized: "protection.category.regional")
        }
    }

    private func categoryDescription(_ id: FilterCategoryID) -> String {
        switch id {
        case .ads: return String(localized: "protection.category.ads.description")
        case .privacy: return String(localized: "protection.category.privacy.description")
        case .annoyances: return String(localized: "protection.category.annoyances.description")
        case .regional: return String(localized: "protection.category.regional.description")
        }
    }
}
