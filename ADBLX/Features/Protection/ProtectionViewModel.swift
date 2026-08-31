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
    var isLoading = false

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

        if status == nil {
            isLoading = true
        }

        let task = Task { [service] in
            await service.fetchStatus()
        }
        inFlightRefreshTask = task
        let newStatus = await task.value
        inFlightRefreshTask = nil
        self.status = newStatus
        self.isLoading = false
        return newStatus
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
        let isBlockedInSettings = updatedCategory.extensionSettingsState != .enabled
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
