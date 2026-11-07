// ADBLX/Filtering/Updates/UpdateThrottle.swift
import Foundation

/// Persists the timestamp of the last *successful* update and answers whether enough
/// time has elapsed to attempt another one. Scheduling policy — not a transactional
/// concern of UpdateCoordinator itself, per Sprint 8.0's "throttle policy stays outside
/// the transactional actor" design decision. Stored as its own metadata file
/// (`update_throttle.json`), not folded into CachedManifest (a transport-cache
/// concept) or UserDefaults (not naturally grouped with the rest of update state).
struct UpdateThrottleRecord: Codable, Equatable {
    var lastSuccessAt: Date
}

actor UpdateThrottle {
    private static let filename = "update_throttle.json"

    private let store: FilterStore
    private let interval: TimeInterval

    init(store: FilterStore, interval: TimeInterval) {
        self.store = store
        self.interval = interval
    }

    /// `true` when no successful update has ever been recorded, or the interval since
    /// the last one has fully elapsed.
    func shouldRun(now: Date) async -> Bool {
        guard let record = await loadRecord() else { return true }
        return now.timeIntervalSince(record.lastSuccessAt) >= interval
    }

    /// Called on `UpdateCoordinator.run()`'s success paths (`.upToDate`, `.updated`) and for a
    /// rejected manifest (`AutomaticUpdate`) — never on `.rolledBack`/`.rollbackFailed`/any
    /// other thrown error, so those remain retryable on the next launch.
    func recordSuccess(at date: Date) async throws {
        let record = UpdateThrottleRecord(lastSuccessAt: date)
        let data = try JSONEncoder().encode(record)
        try await store.writeMetadata(data, filename: Self.filename)
    }

    /// Forgets the last success, so the next check runs an update whatever the interval. For a
    /// caller that just lost the lists previous updates installed.
    static func clear(in store: FilterStore) async {
        try? await store.removeMetadata(filename: filename)
    }

    private func loadRecord() async -> UpdateThrottleRecord? {
        guard let data = try? await store.read(Self.filename, in: .metadata) else { return nil }
        return try? JSONDecoder().decode(UpdateThrottleRecord.self, from: data)
    }
}
