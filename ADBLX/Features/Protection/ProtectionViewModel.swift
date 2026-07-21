// ADBLX/Features/Protection/ProtectionViewModel.swift
import Observation

@Observable
final class ProtectionViewModel {
    private let service: ProtectionService

    var status: ProtectionStatus?
    var isLoading = false

    init(service: ProtectionService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        status = await service.fetchStatus()
        isLoading = false
    }

    func toggleCategory(_ id: FilterCategoryID) async {
        guard var status else { return }
        guard let index = status.categories.firstIndex(where: { $0.id == id }) else { return }
        let newValue = !status.categories[index].isEnabled
        status.categories[index].isEnabled = newValue
        self.status = status
        await service.setCategory(id, enabled: newValue)
    }
}
