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
    /// A participating blocker's Settings check hasn't returned yet.
    case checking
    case active
    case partiallyActive
    case disabledInSettings
    case disabledByUser
    case unavailable
}

/// Derived operational status for an individual category.
enum ProtectionCategoryStatus: Equatable, Sendable {
    /// The blocker's Settings check hasn't returned yet.
    case checking
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
    /// The blocker's state in iOS Settings, or nil while its check is in progress.
    var extensionSettingsState: ContentBlockerSettingsState?
    let ruleCount: Int
    let participatesInProtectionStatus: Bool

    nonisolated init(
        id: FilterCategoryID,
        name: String,
        description: String,
        isEnabled: Bool,
        ruleCount: Int,
        extensionSettingsState: ContentBlockerSettingsState? = .enabled,
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

    /// While the blocker's check is in progress this is the user's choice, so the toggle doesn't
    /// flick off and back on.
    var isEffectivelyActive: Bool {
        guard participatesInProtectionStatus else {
            return isEnabled
        }
        guard let extensionSettingsState else { return isEnabled }
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
        case .enabled?:
            return .active
        case .disabled?:
            return .disabledInSettings
        case .unavailable?:
            return .unavailable
        case nil:
            return .checking
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
/// One blocker's Settings state, as its check returns.
nonisolated struct CategorySettingsState: Equatable, Sendable {
    let category: FilterCategoryID
    let state: ContentBlockerSettingsState
}

nonisolated protocol ProtectionService: Sendable {
    /// Categories, preferences and installed lists, without waiting for any blocker's Settings
    /// check: each participating category's `extensionSettingsState` is nil (checking).
    func fetchStatusBeforeChecks() async -> ProtectionStatus
    /// Each participating blocker's Settings state, in the order the checks return. Finishes
    /// after the last one.
    func extensionSettingsStates() -> AsyncStream<CategorySettingsState>
    func setCategory(_ id: FilterCategoryID, enabled: Bool) async
    func setFilterList(_ id: String, enabled: Bool) async
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
        stateProvider: ContentBlockerStateProviding = AppCompositionRoot.makeContentBlockerStateProvider(),
        descriptors: [ContentBlockerDescriptor] = RealProtectionService.defaultDescriptors
    ) {
        self.store = store
        self.preferencesStore = preferencesStore
        self.stateProvider = stateProvider
        self.descriptors = descriptors
    }

    /// Every participating blocker is checked at once; the gate puts the calls in line, and each
    /// state is reported as soon as its own check returns.
    nonisolated func extensionSettingsStates() -> AsyncStream<CategorySettingsState> {
        let stateProvider = self.stateProvider
        let checks = descriptors
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: CategorySettingsState.self) { group in
                    for descriptor in checks {
                        group.addTask {
                            CategorySettingsState(
                                category: descriptor.category,
                                state: await stateProvider.state(of: descriptor.extensionIdentifier)
                            )
                        }
                    }
                    for await update in group {
                        continuation.yield(update)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func fetchStatusBeforeChecks() async -> ProtectionStatus {
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

            // Checked separately (`extensionSettingsStates()`); nil shows as checking until then.
            let settingsState: ContentBlockerSettingsState?
            if case .some = descriptor { settingsState = nil } else { settingsState = .enabled }

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

        guard activeParticipants.allSatisfy({ $0.extensionSettingsState != nil }) else {
            return .checking
        }
        let states = activeParticipants.compactMap(\.extensionSettingsState)
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
