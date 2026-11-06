import Foundation
import OSLog

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
        await entries().map(\.identifier)
    }

    /// Drops every attempted blocker that reloaded, and adds every one whose reload failed unless
    /// the user turned it off. One whose state couldn't be read is kept for a few attempts only:
    /// it may never be readable, and retrying it for ever would cost a reload every run.
    func record(after results: [ReloadCoordinator.ReloadResult]) async {
        let previous = await entries()
        let attempted = Set(results.map(\.extensionIdentifier))
        var pending = previous.filter { !attempted.contains($0.identifier) }
        var givenUp = 0
        for result in results where !result.success {
            switch await stateProvider.state(of: result.extensionIdentifier) {
            case .enabled:
                pending.append(Entry(identifier: result.extensionIdentifier, unknownStateAttempts: 0))
            case .unavailable:
                let attempts = (previous.first { $0.identifier == result.extensionIdentifier }?.unknownStateAttempts ?? 0) + 1
                if attempts <= Self.maxUnknownStateAttempts {
                    pending.append(Entry(identifier: result.extensionIdentifier, unknownStateAttempts: attempts))
                } else {
                    givenUp += 1
                }
            case .disabled:
                // Not in use, and retrying it would stop every later run reporting up to date.
                break
            }
        }
        if givenUp > 0 {
            // Counts only (docs/Architecture/Logging.md), but never dropped without a record.
            Self.logger.error("reload retry given up blockers=\(givenUp) attempts=\(Self.maxUnknownStateAttempts + 1)")
        }
        guard pending != previous, let data = try? JSONEncoder().encode(pending) else { return }
        try? await store.writeMetadata(data, filename: Self.filename)
    }

    /// Whether any of these failures is for a blocker known to be on. An unknown state alone
    /// doesn't stop a retry run reporting up to date: the user can't act on it.
    func includesEnabledFailure(_ results: [ReloadCoordinator.ReloadResult]) async -> Bool {
        for result in results where !result.success {
            if await stateProvider.state(of: result.extensionIdentifier) == .enabled { return true }
        }
        return false
    }

    private nonisolated struct Entry: Codable, Equatable {
        let identifier: String
        /// Failed attempts while the blocker's state couldn't be read; 0 once it reads as on.
        let unknownStateAttempts: Int
    }

    private func entries() async -> [Entry] {
        guard let data = try? await store.read(Self.filename, in: .metadata) else { return [] }
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) { return entries }
        // Written before retry counts existed: every entry was for an enabled blocker.
        let identifiers = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return identifiers.map { Entry(identifier: $0, unknownStateAttempts: 0) }
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
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "PendingReloads")
    private static let maxUnknownStateAttempts = 3
}
