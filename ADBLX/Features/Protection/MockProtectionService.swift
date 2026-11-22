import Foundation

/// Fixed sample data for previews and the mock UI dependencies.
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

    func fetchStatusBeforeChecks() async -> ProtectionStatus { status }

    nonisolated func extensionSettingsStates() -> AsyncStream<CategorySettingsState> {
        AsyncStream { $0.finish() }
    }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        guard let index = status.categories.firstIndex(where: { $0.id == id }) else { return }
        status.categories[index].isEnabled = enabled
    }

    func setFilterList(_ id: String, enabled: Bool) async {
        guard let index = status.filterLists.firstIndex(where: { $0.id == id }) else { return }
        status.filterLists[index].isEnabled = enabled
    }
}
