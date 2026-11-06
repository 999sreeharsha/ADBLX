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

/// What happened to an allowlist edit, which recompiles every installed group.
nonisolated enum AllowlistEditOutcome: Equatable, Sendable {
    /// Saved, and Safari has the new rules. Also an edit that changed nothing.
    case applied
    /// The rules couldn't be rebuilt, so the edit was undone.
    case reverted
    /// Saved, but Safari didn't take the new rules. The next update run retries the reload.
    case notReloaded
}

/// What Settings needs from the backend (FR-08's per-site allowlist).
nonisolated protocol SettingsService: Sendable {
    func fetchSnapshot() async -> SettingsSnapshot
    @discardableResult func addAllowlistEntry(domain: String) async -> AllowlistEditOutcome
    @discardableResult func removeAllowlistEntry(id: String) async -> AllowlistEditOutcome
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

    func addAllowlistEntry(domain: String) async -> AllowlistEditOutcome {
        snapshot.allowlist.append(AllowlistEntry(id: UUID().uuidString, domain: domain))
        return .applied
    }

    func removeAllowlistEntry(id: String) async -> AllowlistEditOutcome {
        snapshot.allowlist.removeAll { $0.id == id }
        return .applied
    }
}

/// Real SettingsService coordinating canonical AllowlistStore persistence,
/// iCloud sync coordination, and deterministic FilterPipeline recompilation.
actor RealSettingsService: SettingsService {
    private let allowlistStore: AllowlistStore
    private let pipeline: FilterPipeline?
    private let iCloudSyncCoordinator: ICloudSyncCoordinator?
    private let stateProvider: ContentBlockerStateProviding

    init(
        allowlistStore: AllowlistStore,
        pipeline: FilterPipeline? = nil,
        iCloudSyncCoordinator: ICloudSyncCoordinator? = nil,
        stateProvider: ContentBlockerStateProviding = SystemContentBlockerStateProvider()
    ) {
        self.allowlistStore = allowlistStore
        self.pipeline = pipeline
        self.iCloudSyncCoordinator = iCloudSyncCoordinator
        self.stateProvider = stateProvider
    }

    func fetchSnapshot() async -> SettingsSnapshot {
        let allowlist = await allowlistStore.load()
        let syncActive = await iCloudSyncCoordinator?.isSyncActive() ?? false
        return SettingsSnapshot(iCloudSyncEnabled: syncActive, allowlist: allowlist)
    }

    func addAllowlistEntry(domain: String) async -> AllowlistEditOutcome {
        let existingIDs = Set(await allowlistStore.load().map(\.id))
        guard let entry = try? await allowlistStore.add(domain: domain) else { return .applied }
        // Already allowlisted: nothing to rebuild, and undoing a failed rebuild would remove it.
        guard !existingIDs.contains(entry.id) else { return .applied }
        guard let pipeline else {
            await iCloudSyncCoordinator?.recordLocalAddition(domain: domain)
            return .applied
        }
        do {
            let results = try await pipeline.syncAllowlist()
            await iCloudSyncCoordinator?.recordLocalAddition(domain: domain)
            return await outcome(of: results)
        } catch {
            try? await allowlistStore.remove(id: entry.id)
            return .reverted
        }
    }

    func removeAllowlistEntry(id: String) async -> AllowlistEditOutcome {
        let previous = await allowlistStore.load()
        guard let target = previous.first(where: { $0.id == id }) else { return .applied }
        try? await allowlistStore.remove(id: id)
        guard let pipeline else {
            await iCloudSyncCoordinator?.recordLocalDeletion(domain: target.domain)
            return .applied
        }
        do {
            let results = try await pipeline.syncAllowlist()
            await iCloudSyncCoordinator?.recordLocalDeletion(domain: target.domain)
            return await outcome(of: results)
        } catch {
            _ = try? await allowlistStore.add(domain: target.domain)
            return .reverted
        }
    }

    private func outcome(of results: [PipelineResult]) async -> AllowlistEditOutcome {
        let reloads = results.first?.reloadResults ?? []
        return await PendingReloads.safariMissedRules(reloads, stateProvider: stateProvider) ? .notReloaded : .applied
    }
}
