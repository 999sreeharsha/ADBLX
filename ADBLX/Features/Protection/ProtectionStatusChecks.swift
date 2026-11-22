import Foundation

extension ProtectionService {
    /// The status once every check has returned.
    func fetchStatus() async -> ProtectionStatus {
        let states = extensionSettingsStates()
        var status = await fetchStatusBeforeChecks()
        for await update in states {
            status = status.settingExtensionState(update.state, for: update.category)
        }
        return status
    }
}

extension ProtectionStatus {
    /// This status with one blocker's Settings state filled in and the master state recomputed.
    nonisolated func settingExtensionState(
        _ state: ContentBlockerSettingsState?, for id: FilterCategoryID
    ) -> ProtectionStatus {
        var categories = self.categories
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return self }
        categories[index].extensionSettingsState = state
        return ProtectionStatus(
            masterState: RealProtectionService.computeMasterState(from: categories),
            categories: categories,
            filterLists: filterLists
        )
    }
}
