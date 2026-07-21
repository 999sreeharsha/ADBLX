// ADBLX/Features/Protection/ProtectionService.swift
import Foundation

/// UI-facing mirror of the backend's FilterGroup (Filtering/Models/FilterManifest.swift).
/// Deliberately a separate type — the UI layer never imports FilterGroup directly
/// (Sprint 4 spec §5).
enum FilterCategoryID: Equatable {
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
            ProtectionCategory(id: .ads, name: "Ads", description: "Blocks display and video ads", isEnabled: true, ruleCount: 62_000),
            ProtectionCategory(id: .privacy, name: "Privacy", description: "Blocks trackers and analytics scripts", isEnabled: true, ruleCount: 48_500),
            ProtectionCategory(id: .annoyances, name: "Annoyances", description: "Hides cookie banners and popups", isEnabled: false, ruleCount: 21_000),
            ProtectionCategory(id: .regional, name: "Regional", description: "Extra rules for regional ad networks", isEnabled: false, ruleCount: 10_542),
        ],
        filterLists: [
            FilterListEntry(id: "easylist", name: "EasyList", category: .ads, version: "2026-07-15", isEnabled: true, isPremium: false),
            FilterListEntry(id: "easyprivacy", name: "EasyPrivacy", category: .privacy, version: "2026-07-15", isEnabled: true, isPremium: false),
            FilterListEntry(id: "fanboy-annoyances", name: "Fanboy's Annoyances", category: .annoyances, version: "2026-07-10", isEnabled: false, isPremium: true),
            FilterListEntry(id: "regional-in", name: "Regional: India", category: .regional, version: "2026-07-01", isEnabled: false, isPremium: true),
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
