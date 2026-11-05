// ADBLX/Features/Settings/SettingsViewModel.swift
import Observation

@Observable
final class SettingsViewModel {
    private let service: SettingsService

    var snapshot: SettingsSnapshot?
    var isLoading = false
    /// An edit recompiles rules, and waits first if a filter update is running, which can take
    /// about 10 seconds per group. The work itself runs off the main actor in the service.
    private(set) var isApplyingAllowlistEdit = false

    init(service: SettingsService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        snapshot = await service.fetchSnapshot()
        isLoading = false
    }

    func addAllowlistEntry(domain: String) async {
        isApplyingAllowlistEdit = true
        defer { isApplyingAllowlistEdit = false }
        await service.addAllowlistEntry(domain: domain)
        snapshot = await service.fetchSnapshot()
    }

    func removeAllowlistEntry(id: String) async {
        isApplyingAllowlistEdit = true
        defer { isApplyingAllowlistEdit = false }
        await service.removeAllowlistEntry(id: id)
        snapshot = await service.fetchSnapshot()
    }
}
