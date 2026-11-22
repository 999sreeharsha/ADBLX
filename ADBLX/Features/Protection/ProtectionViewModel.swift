// ADBLX/Features/Protection/ProtectionViewModel.swift
import Foundation
import Observation

enum ProtectionRefreshReason: Sendable {
    case initialLoad
    case pullToRefresh
    case foreground
}

@Observable
final class ProtectionViewModel {
    private let service: ProtectionService

    var status: ProtectionStatus?

    var pendingSettingsCategory: ProtectionCategory?
    var showSettingsPrompt = false

    private var inFlightRefreshTask: Task<ProtectionStatus, Never>?

    init(service: ProtectionService) {
        self.service = service
    }

    func load() async {
        await refreshProtectionStatus(reason: .initialLoad)
    }

    @discardableResult
    func refreshProtectionStatus(reason: ProtectionRefreshReason) async -> ProtectionStatus? {
        if let existing = inFlightRefreshTask {
            return await existing.value
        }

        let task = Task { await self.loadStatus() }
        inFlightRefreshTask = task
        let newStatus = await task.value
        inFlightRefreshTask = nil
        return newStatus
    }

    /// Shows the categories at once and fills in each blocker's Settings state as its own check
    /// returns: checks wait their turn in `ContentBlockerCallGate`, so they can take a while.
    /// On a refresh, a blocker keeps its last known state until its new check returns.
    private func loadStatus() async -> ProtectionStatus {
        let checks = service.extensionSettingsStates()
        var current = await service.fetchStatusBeforeChecks()
        if let previous = status {
            for category in current.categories where category.extensionSettingsState == nil {
                let known = previous.categories.first { $0.id == category.id }?.extensionSettingsState
                current = current.settingExtensionState(known, for: category.id)
            }
        }
        status = current
        for await update in checks {
            // Applied to whatever is shown now, so a toggle made meanwhile is kept.
            status = status?.settingExtensionState(update.state, for: update.category)
        }
        return status ?? current
    }

    func toggleCategory(_ id: FilterCategoryID) async {
        guard var currentStatus = status else { return }
        guard let index = currentStatus.categories.firstIndex(where: { $0.id == id }) else { return }

        let category = currentStatus.categories[index]
        let willBeActive: Bool

        if category.isEffectivelyActive {
            willBeActive = false
            currentStatus.categories[index].isEnabled = false
        } else {
            willBeActive = true
            currentStatus.categories[index].isEnabled = true
        }

        // Locally recompute aggregate state to remain responsive without an unnecessary state query roundtrip
        let newMasterState = RealProtectionService.computeMasterState(from: currentStatus.categories)
        self.status = ProtectionStatus(
            masterState: newMasterState,
            categories: currentStatus.categories,
            filterLists: currentStatus.filterLists
        )

        let updatedCategory = currentStatus.categories[index]
        // Unknown while its check is in progress: no prompt until the check says it's off.
        let isBlockedInSettings = updatedCategory.extensionSettingsState.map { $0 != .enabled } ?? false
        if willBeActive && updatedCategory.participatesInProtectionStatus && isBlockedInSettings {
            self.pendingSettingsCategory = updatedCategory
            self.showSettingsPrompt = true
        }

        await service.setCategory(id, enabled: willBeActive)
    }

    func toggleFilterList(_ id: String) async {
        guard var currentStatus = status else { return }
        guard let index = currentStatus.filterLists.firstIndex(where: { $0.id == id }) else { return }
        let newValue = !currentStatus.filterLists[index].isEnabled
        currentStatus.filterLists[index].isEnabled = newValue
        self.status = currentStatus
        await service.setFilterList(id, enabled: newValue)
    }
}
