import Foundation

/// Content blockers whose last reload failed, kept in `Metadata/pending_reloads.json`. The rules
/// on disk are already committed by then, so nothing else would reload that extension: the next
/// update run retries these even when the manifest is unchanged.
nonisolated struct PendingReloads: Sendable {
    private let store: FilterStore
    private let stateProvider: ContentBlockerStateProviding

    init(store: FilterStore, stateProvider: ContentBlockerStateProviding) {
        self.store = store
        self.stateProvider = stateProvider
    }

    func identifiers() async -> [String] {
        guard let data = try? await store.read(Self.filename, in: .metadata) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Drops every attempted blocker that reloaded, and adds every one in use whose reload failed.
    func record(after results: [ReloadCoordinator.ReloadResult]) async {
        let previous = await identifiers()
        let attempted = Set(results.map(\.extensionIdentifier))
        var pending = previous.filter { !attempted.contains($0) }
        // Only a blocker in use: one the user has turned off isn't, and retrying it would stop
        // every later run reporting up to date.
        for result in results where !result.success {
            if await stateProvider.state(of: result.extensionIdentifier) == .enabled {
                pending.append(result.extensionIdentifier)
            }
        }
        guard pending != previous, let data = try? JSONEncoder().encode(pending) else { return }
        try? await store.writeMetadata(data, filename: Self.filename)
    }

    /// Whether Safari may still be running older rules than the ones on disk. A blocker the user
    /// has turned off isn't in use, so its failed reload doesn't count.
    static func safariMissedRules(
        _ results: [ReloadCoordinator.ReloadResult],
        stateProvider: ContentBlockerStateProviding
    ) async -> Bool {
        for result in results where !result.success {
            if await stateProvider.state(of: result.extensionIdentifier) != .disabled { return true }
        }
        return false
    }

    private static let filename = "pending_reloads.json"
}
