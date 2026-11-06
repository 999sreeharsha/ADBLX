// ADBLX/Features/Settings/SettingsViewModel.swift
import Foundation
import Observation

@Observable
final class SettingsViewModel {
    private let service: SettingsService

    var snapshot: SettingsSnapshot?
    var isLoading = false
    /// An edit recompiles rules, and waits first if a filter update is running, which can take
    /// about 10 seconds per group. The work itself runs off the main actor in the service.
    private(set) var isApplyingAllowlistEdit = false
    /// Why the last edit didn't take effect, until the next edit.
    private(set) var allowlistEditError: String?

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
        allowlistEditError = Self.message(for: await service.addAllowlistEntry(domain: domain))
        snapshot = await service.fetchSnapshot()
    }

    func removeAllowlistEntry(id: String) async {
        isApplyingAllowlistEdit = true
        defer { isApplyingAllowlistEdit = false }
        allowlistEditError = Self.message(for: await service.removeAllowlistEntry(id: id))
        snapshot = await service.fetchSnapshot()
    }

    private static func message(for outcome: AllowlistEditOutcome) -> String? {
        switch outcome {
        case .applied: return nil
        case .reverted: return String(localized: "settings.allowlist.compileFailed")
        // The same words as the update sheet: it's the same failure, and the same fix.
        case .notReloaded: return String(localized: "updateprogress.status.reloadFailed")
        }
    }
}
