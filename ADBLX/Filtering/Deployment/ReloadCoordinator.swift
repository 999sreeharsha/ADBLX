// ADBLX/Filtering/Deployment/ReloadCoordinator.swift
import Foundation
import SafariServices

/// The ONLY call site in the app for `SFContentBlockerManager.reloadContentBlocker`.
/// Every deployment path (manual update, automatic update, rollback) must go through this
/// type — never call `SFContentBlockerManager` directly elsewhere.
///
/// Maps to FR-06 (reload affected extensions after compile; report per-extension status).
/// Target: main app ONLY (extensions cannot reload themselves or each other).
///
/// Bounded by `timeoutSeconds` — see this task's "Why this needs a timeout" note in the plan
/// for why a plain TaskGroup race doesn't work here and an unstructured Task does.
actor ReloadCoordinator {
    struct ReloadResult {
        var extensionIdentifier: String
        var success: Bool
        var error: Error?
        /// Wall-clock time for the reload call. Cheap to capture now, and gives FR-06
        /// diagnostics (e.g. "reload of X is taking longer than expected") without a
        /// separate instrumentation pass later.
        var duration: TimeInterval
    }

    enum ReloadError: Error {
        case underlying(Error)
        case timedOut
    }

    private let timeoutSeconds: Int

    init(timeoutSeconds: Int = 10) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Reloads a single Content Blocker extension by its bundle identifier.
    /// Errors are returned, never swallowed — callers (typically a view model) surface
    /// "enable in Settings"-style messaging per FR-06's UI requirement. Never hangs past
    /// `timeoutSeconds`, even if SFContentBlockerManager's completion handler never fires.
    func reload(extensionIdentifier: String) async -> ReloadResult {
        let start = Date()
        let timeoutSeconds = self.timeoutSeconds

        return await withCheckedContinuation { (continuation: CheckedContinuation<ReloadResult, Never>) in
            let resumeGuard = ResumeOnce()

            SFContentBlockerManager.reloadContentBlocker(withIdentifier: extensionIdentifier) { error in
                guard resumeGuard.markAndCheckFirst() else { return }
                continuation.resume(returning: ReloadResult(
                    extensionIdentifier: extensionIdentifier,
                    success: error == nil,
                    error: error,
                    duration: Date().timeIntervalSince(start)
                ))
            }

            // Unstructured, not a TaskGroup child: see the task-level note on why a
            // TaskGroup's implicit wait-for-all-children would defeat the timeout entirely.
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard resumeGuard.markAndCheckFirst() else { return }
                continuation.resume(returning: ReloadResult(
                    extensionIdentifier: extensionIdentifier,
                    success: false,
                    error: ReloadError.timedOut,
                    duration: Date().timeIntervalSince(start)
                ))
            }
        }
    }

    /// Reloads multiple extensions and returns per-extension results — never a single
    /// aggregated boolean, since FR-06 requires reporting per-extension status in the UI.
    func reload(extensionIdentifiers: [String]) async -> [ReloadResult] {
        var results: [ReloadResult] = []
        for identifier in extensionIdentifiers {
            results.append(await reload(extensionIdentifier: identifier))
        }
        return results
    }
}

/// Guarantees a `CheckedContinuation` is resumed exactly once when two independent callback
/// sources (the real SFContentBlockerManager callback and the timeout Task) race to resume it.
/// A double-resume crashes at runtime, so this lock-guarded flag is load-bearing, not decor.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func markAndCheckFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasResumed { return false }
        hasResumed = true
        return true
    }
}
