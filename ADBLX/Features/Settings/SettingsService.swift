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

/// What Settings needs from the backend (FR-08's per-site allowlist).
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
            AllowlistEntry(id: "2", domain: "shop.example.com")
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

/// Real SettingsService coordinating canonical AllowlistStore persistence,
/// iCloud sync coordination, and deterministic FilterPipeline recompilation.
actor RealSettingsService: SettingsService {
    private let allowlistStore: AllowlistStore
    private let pipeline: FilterPipeline?
    private let iCloudSyncCoordinator: ICloudSyncCoordinator?

    init(
        allowlistStore: AllowlistStore,
        pipeline: FilterPipeline? = nil,
        iCloudSyncCoordinator: ICloudSyncCoordinator? = nil
    ) {
        self.allowlistStore = allowlistStore
        self.pipeline = pipeline
        self.iCloudSyncCoordinator = iCloudSyncCoordinator
    }

    func fetchSnapshot() async -> SettingsSnapshot {
        let allowlist = await allowlistStore.load()
        let syncActive = await iCloudSyncCoordinator?.isSyncActive() ?? false
        return SettingsSnapshot(iCloudSyncEnabled: syncActive, allowlist: allowlist)
    }

    func addAllowlistEntry(domain: String) async {
        guard let entry = try? await allowlistStore.add(domain: domain) else { return }
        if let pipeline {
            do {
                _ = try await pipeline.syncAllowlist()
                await iCloudSyncCoordinator?.recordLocalAddition(domain: domain)
            } catch {
                try? await allowlistStore.remove(id: entry.id)
            }
        } else {
            await iCloudSyncCoordinator?.recordLocalAddition(domain: domain)
        }
    }

    func removeAllowlistEntry(id: String) async {
        let previous = await allowlistStore.load()
        guard let target = previous.first(where: { $0.id == id }) else { return }
        try? await allowlistStore.remove(id: id)
        if let pipeline {
            do {
                _ = try await pipeline.syncAllowlist()
                await iCloudSyncCoordinator?.recordLocalDeletion(domain: target.domain)
            } catch {
                _ = try? await allowlistStore.add(domain: target.domain)
            }
        } else {
            await iCloudSyncCoordinator?.recordLocalDeletion(domain: target.domain)
        }
    }
}
