// ADBLX/Features/Settings/SettingsViewModel.swift
import Observation

@Observable
final class SettingsViewModel {
    private let service: SettingsService

    var snapshot: SettingsSnapshot?
    var isLoading = false

    init(service: SettingsService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        snapshot = await service.fetchSnapshot()
        isLoading = false
    }

    func addAllowlistEntry(domain: String) async {
        await service.addAllowlistEntry(domain: domain)
        snapshot = await service.fetchSnapshot()
    }

    func removeAllowlistEntry(id: String) async {
        await service.removeAllowlistEntry(id: id)
        snapshot = await service.fetchSnapshot()
    }
}
