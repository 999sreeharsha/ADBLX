// ADBLX/Features/Protection/ProtectionService.swift
import Foundation

/// UI-facing mirror of the backend's FilterGroup (Filtering/Models/FilterManifest.swift).
/// Deliberately a separate type — the UI layer never imports FilterGroup directly
/// (Sprint 4 spec §5). String raw value + CaseIterable: the canonical, single source
/// of the four-category list — FilterPreferencesStore, RealProtectionService, and
/// AdvancedFilterListsView all iterate FilterCategoryID.allCases rather than each
/// keeping their own hardcoded array (Sprint 5B design doc).
enum FilterCategoryID: String, CaseIterable, Equatable, Codable, Sendable {
    case ads
    case privacy
    case annoyances
    case regional
}

/// Master protection state across all participating content blockers.
enum SafariProtectionState: Equatable, Sendable {
    case active
    case partiallyActive
    case disabledInSettings
    case disabledByUser
    case unavailable
}

/// Derived operational status for an individual category.
enum ProtectionCategoryStatus: Equatable, Sendable {
    case active
    case disabledByUser
    case disabledInSettings
    case unavailable
}

struct ProtectionCategory: Equatable, Identifiable, Sendable {
    var id: FilterCategoryID
    let name: String
    let description: String
    var isEnabled: Bool
    var preferenceEnabled: Bool {
        get { isEnabled }
        set { isEnabled = newValue }
    }
    var extensionSettingsState: ContentBlockerSettingsState
    let ruleCount: Int
    let participatesInProtectionStatus: Bool

    nonisolated init(
        id: FilterCategoryID,
        name: String,
        description: String,
        isEnabled: Bool,
        ruleCount: Int,
        extensionSettingsState: ContentBlockerSettingsState = .enabled,
        participatesInProtectionStatus: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
        self.ruleCount = ruleCount
        self.extensionSettingsState = extensionSettingsState
        self.participatesInProtectionStatus = participatesInProtectionStatus
    }

    var isEffectivelyActive: Bool {
        guard participatesInProtectionStatus else {
            return isEnabled
        }
        return isEnabled && extensionSettingsState == .enabled
    }

    var status: ProtectionCategoryStatus {
        guard participatesInProtectionStatus else {
            return isEnabled ? .active : .disabledByUser
        }
        guard isEnabled else {
            return .disabledByUser
        }
        switch extensionSettingsState {
        case .enabled:
            return .active
        case .disabled:
            return .disabledInSettings
        case .unavailable:
            return .unavailable
        }
    }
}

/// No ruleCount: CompositionService/FilterPipeline only ever compute a
/// group-level aggregate (docs/gotchas.md) — there is no real per-source
/// count to show at this granularity. The rule-count meter FR-09 calls for
/// lives on ProtectionCategory (Task 1), which is genuinely group-level.
struct FilterListEntry: Equatable, Identifiable, Sendable {
    var id: String
    let name: String
    let category: FilterCategoryID
    let version: String
    var isEnabled: Bool
    let isPremium: Bool

    nonisolated init(
        id: String,
        name: String,
        category: FilterCategoryID,
        version: String,
        isEnabled: Bool,
        isPremium: Bool
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.version = version
        self.isEnabled = isEnabled
        self.isPremium = isPremium
    }
}

struct ProtectionStatus: Equatable, Sendable {
    var isSafariExtensionEnabled: Bool {
        masterState == .active || masterState == .partiallyActive
    }
    let masterState: SafariProtectionState
    var categories: [ProtectionCategory]
    var filterLists: [FilterListEntry] = []

    nonisolated init(
        masterState: SafariProtectionState,
        categories: [ProtectionCategory],
        filterLists: [FilterListEntry] = []
    ) {
        self.masterState = masterState
        self.categories = categories
        self.filterLists = filterLists
    }

    nonisolated init(
        isSafariExtensionEnabled: Bool,
        categories: [ProtectionCategory],
        filterLists: [FilterListEntry] = []
    ) {
        self.masterState = isSafariExtensionEnabled ? .active : .disabledInSettings
        self.categories = categories
        self.filterLists = filterLists
    }
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
        masterState: .active,
        categories: [
            ProtectionCategory(
                id: .ads, name: "Ads", description: "Blocks display and video ads",
                isEnabled: true, ruleCount: 62_000,
                extensionSettingsState: .enabled, participatesInProtectionStatus: true
            ),
            ProtectionCategory(
                id: .privacy, name: "Privacy", description: "Blocks trackers and analytics scripts",
                isEnabled: true, ruleCount: 48_500,
                extensionSettingsState: .enabled, participatesInProtectionStatus: true
            ),
            ProtectionCategory(
                id: .annoyances, name: "Annoyances", description: "Hides cookie banners and popups",
                isEnabled: false, ruleCount: 21_000,
                extensionSettingsState: .enabled, participatesInProtectionStatus: true
            ),
            ProtectionCategory(
                id: .regional, name: "Regional", description: "Extra rules for regional ad networks",
                isEnabled: false, ruleCount: 10_542,
                extensionSettingsState: .enabled, participatesInProtectionStatus: true
            )
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
            )
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
    private let stateProvider: ContentBlockerStateProviding
    private let descriptors: [ContentBlockerDescriptor]

    nonisolated static var defaultDescriptors: [ContentBlockerDescriptor] {
        let base = Bundle.main.bundleIdentifier ?? "com.ADBLX.ADBLX"
        return [
            ContentBlockerDescriptor(
                category: .ads,
                extensionIdentifier: "\(base).AdsBlocker",
                participatesInProtectionStatus: true
            ),
            ContentBlockerDescriptor(
                category: .privacy,
                extensionIdentifier: "\(base).PrivacyBlocker",
                participatesInProtectionStatus: true
            ),
            ContentBlockerDescriptor(
                category: .annoyances,
                extensionIdentifier: "\(base).AnnoyancesBlocker",
                participatesInProtectionStatus: true
            ),
            ContentBlockerDescriptor(
                category: .regional,
                extensionIdentifier: "\(base).RegionalBlocker",
                participatesInProtectionStatus: true
            )
        ]
    }

    init(
        store: FilterStore,
        preferencesStore: FilterPreferencesStore,
        stateProvider: ContentBlockerStateProviding = SystemContentBlockerStateProvider(),
        descriptors: [ContentBlockerDescriptor] = RealProtectionService.defaultDescriptors
    ) {
        self.store = store
        self.preferencesStore = preferencesStore
        self.stateProvider = stateProvider
        self.descriptors = descriptors
    }

    func fetchStatus() async -> ProtectionStatus {
        let preferences = await preferencesStore.load()
        let filters = (try? await loadInstalledFilters()) ?? []
        let filtersByGroup = Dictionary(grouping: filters, by: \.group)
        let descriptorMap = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.category, $0) })

        var categories: [ProtectionCategory] = []
        for categoryID in FilterCategoryID.allCases {
            let group = filterGroup(for: categoryID)
            let groupFilters = filtersByGroup[group] ?? []
            let uniqueRuleCount = groupFilters.first?.ruleCount ?? 0
            let descriptor = descriptorMap[categoryID]

            let settingsState: ContentBlockerSettingsState
            if let descriptor {
                settingsState = await stateProvider.state(of: descriptor.extensionIdentifier)
            } else {
                settingsState = .enabled
            }

            let category = ProtectionCategory(
                id: categoryID,
                name: categoryDisplayName(categoryID),
                description: categoryDescription(categoryID),
                isEnabled: preferences.categories[categoryID] ?? true,
                ruleCount: uniqueRuleCount,
                extensionSettingsState: settingsState,
                participatesInProtectionStatus: descriptor?.participatesInProtectionStatus ?? false
            )
            categories.append(category)
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

        let masterState = Self.computeMasterState(from: categories)
        return ProtectionStatus(
            masterState: masterState,
            categories: categories,
            filterLists: filterLists
        )
    }

    nonisolated static func computeMasterState(from categories: [ProtectionCategory]) -> SafariProtectionState {
        let activeParticipants = categories.filter { $0.participatesInProtectionStatus && $0.isEnabled }
        guard !activeParticipants.isEmpty else {
            return .disabledByUser
        }

        let states = activeParticipants.map(\.extensionSettingsState)
        if states.contains(where: { if case .unavailable = $0 { return true } else { return false } }) {
            return .unavailable
        }

        let enabledCount = states.filter { $0 == .enabled }.count
        let disabledCount = states.filter { $0 == .disabled }.count

        if enabledCount == states.count {
            return .active
        } else if disabledCount == states.count {
            return .disabledInSettings
        } else {
            return .partiallyActive
        }
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
