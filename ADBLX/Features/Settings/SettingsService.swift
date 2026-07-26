// ADBLX/Features/Settings/SettingsService.swift
import Foundation

struct AllowlistEntry: Codable, Equatable, Identifiable {
    let id: String
    let domain: String
}

struct SettingsSnapshot: Equatable {
    let iCloudSyncEnabled: Bool
    var allowlist: [AllowlistEntry]
}

/// What Settings needs from the backend (FR-08's per-site allowlist). A later
/// sprint's real implementation persists to the shared App Group container.
protocol SettingsService: Sendable {
    func fetchSnapshot() async -> SettingsSnapshot
    func addAllowlistEntry(domain: String) async
    func removeAllowlistEntry(id: String) async
}

actor MockSettingsService: SettingsService {
    private var snapshot = SettingsSnapshot(
        iCloudSyncEnabled: false,
        allowlist: [
            AllowlistEntry(id: "1", domain: "news.example.com"),
            AllowlistEntry(id: "2", domain: "shop.example.com"),
        ]
    )

    func fetchSnapshot() async -> SettingsSnapshot { snapshot }

    func addAllowlistEntry(domain: String) async {
        snapshot.allowlist.append(AllowlistEntry(id: UUID().uuidString, domain: domain))
    }

    func removeAllowlistEntry(id: String) async {
        snapshot.allowlist.removeAll { $0.id == id }
    }
}

/// Real SettingsService. iCloudSyncEnabled stays hardcoded false — no iCloud sync
/// backend exists yet, unchanged scope for Sprint 5B (Sprint 5B design doc).
/// Allowlist is real and persisted via AllowlistStore, but storage-only: it does
/// not yet exempt anything from blocking.
actor RealSettingsService: SettingsService {
    private let allowlistStore: AllowlistStore

    init(allowlistStore: AllowlistStore) {
        self.allowlistStore = allowlistStore
    }

    func fetchSnapshot() async -> SettingsSnapshot {
        let allowlist = await allowlistStore.load()
        return SettingsSnapshot(iCloudSyncEnabled: false, allowlist: allowlist)
    }

    func addAllowlistEntry(domain: String) async {
        await allowlistStore.add(domain: domain)
    }

    func removeAllowlistEntry(id: String) async {
        await allowlistStore.remove(id: id)
    }
}
