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

struct ProtectionStatus: Equatable {
    let isSafariExtensionEnabled: Bool
    var categories: [ProtectionCategory]
}

/// What Safari Protection and Advanced Filter Lists need from the backend.
/// A later sprint's real implementation translates FilterPipeline/FilterManifest
/// state into these screen-shaped types.
protocol ProtectionService: Sendable {
    func fetchStatus() async -> ProtectionStatus
    func setCategory(_ id: FilterCategoryID, enabled: Bool) async
}

actor MockProtectionService: ProtectionService {
    private var status = ProtectionStatus(
        isSafariExtensionEnabled: true,
        categories: [
            ProtectionCategory(id: .ads, name: "Ads", description: "Blocks display and video ads", isEnabled: true, ruleCount: 62_000),
            ProtectionCategory(id: .privacy, name: "Privacy", description: "Blocks trackers and analytics scripts", isEnabled: true, ruleCount: 48_500),
            ProtectionCategory(id: .annoyances, name: "Annoyances", description: "Hides cookie banners and popups", isEnabled: false, ruleCount: 21_000),
            ProtectionCategory(id: .regional, name: "Regional", description: "Extra rules for regional ad networks", isEnabled: false, ruleCount: 10_542),
        ]
    )

    func fetchStatus() async -> ProtectionStatus { status }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        guard let index = status.categories.firstIndex(where: { $0.id == id }) else { return }
        status.categories[index].isEnabled = enabled
    }
}
