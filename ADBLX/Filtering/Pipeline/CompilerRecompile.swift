import Foundation

/// The launch-time compiler-version recompile: runs `FilterPipeline.recompileIfCompilerChanged`
/// when the throttle allows.
enum CompilerRecompile {
    /// A failure is retried after `RecompileThrottle.failureGap`, and not at all after
    /// `maxConsecutiveFailures` on the same build: a group that fails every time (a full disk, a
    /// compiler bug on one list) would otherwise cost a full recompile on every launch.
    static func runIfDue(
        pipeline: FilterPipeline,
        throttle: RecompileThrottle,
        reloadStrategy: ReloadStrategy = .immediate,
        now: Date = Date()
    ) async {
        guard await throttle.shouldAttempt(now: now) else { return }
        do {
            _ = try await pipeline.recompileIfCompilerChanged(reloadStrategy: reloadStrategy)
            await throttle.recordSuccess()
        } catch {
            try? await throttle.recordFailure(at: now)
        }
    }
}

struct RecompileAttemptsRecord: Codable, Equatable {
    /// The app build that failed; a new build starts the count again.
    var build: String
    var consecutiveFailures: Int
    var lastFailureAt: Date
}

/// Persists consecutive recompile failures (`recompile_attempts.json`). Written outside the
/// transaction gate, as `UpdateThrottle` is; a rollback that overlaps it costs at most one
/// extra attempt.
actor RecompileThrottle {
    /// The minimum gap ManifestTrust.md gives network failures.
    static let failureGap: TimeInterval = 15 * 60
    static let maxConsecutiveFailures = 3

    private static let filename = "recompile_attempts.json"

    private let store: FilterStore
    private let build: String

    init(store: FilterStore, build: String) {
        self.store = store
        self.build = build
    }

    func shouldAttempt(now: Date) async -> Bool {
        guard let record = await loadRecord(), record.build == build else { return true }
        guard record.consecutiveFailures < Self.maxConsecutiveFailures else { return false }
        return now.timeIntervalSince(record.lastFailureAt) >= Self.failureGap
    }

    func recordFailure(at date: Date) async throws {
        let previous = await loadRecord().flatMap { $0.build == build ? $0.consecutiveFailures : nil } ?? 0
        let record = RecompileAttemptsRecord(build: build, consecutiveFailures: previous + 1, lastFailureAt: date)
        try await store.writeMetadata(JSONEncoder().encode(record), filename: Self.filename)
    }

    func recordSuccess() async {
        try? await store.removeMetadata(filename: Self.filename)
    }

    private func loadRecord() async -> RecompileAttemptsRecord? {
        guard let data = try? await store.read(Self.filename, in: .metadata) else { return nil }
        return try? JSONDecoder().decode(RecompileAttemptsRecord.self, from: data)
    }
}
