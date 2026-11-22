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
/// The app uses one instance, from `AppCompositionRoot.makeReloadCoordinator()`. Each reload goes
/// through `ContentBlockerCallGate`, which also bounds it by `timeoutSeconds`.
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

    typealias ReloadOperation = @Sendable (_ extensionIdentifier: String, _ completion: @escaping @Sendable (Error?) -> Void) -> Void

    private let timeoutSeconds: Int
    private let gate: ContentBlockerCallGate
    private let reloadOperation: ReloadOperation

    init(
        timeoutSeconds: Int = 10,
        gate: ContentBlockerCallGate = .shared,
        reloadOperation: @escaping ReloadOperation = { identifier, completion in
            SFContentBlockerManager.reloadContentBlocker(withIdentifier: identifier) { completion($0) }
        }
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.gate = gate
        self.reloadOperation = reloadOperation
    }

    /// Reloads a single Content Blocker extension by its bundle identifier.
    /// Errors are returned, never swallowed — callers (typically a view model) surface
    /// "enable in Settings"-style messaging per FR-06's UI requirement. Never hangs past
    /// `timeoutSeconds`, even if SFContentBlockerManager's completion handler never fires.
    func reload(extensionIdentifier: String) async -> ReloadResult {
        let result = await performReload(extensionIdentifier: extensionIdentifier)
        ReloadResultLog.shared.record(
            extensionIdentifier: extensionIdentifier, success: result.success, error: result.error
        )
        return result
    }

    private func performReload(extensionIdentifier: String) async -> ReloadResult {
        let start = Date()
        let reloadOperation = self.reloadOperation
        let timeout = Duration.seconds(timeoutSeconds)
        let outcome: ContentBlockerCallGate.Outcome<Error?> = await gate.call(timeout: timeout) { answer in
            reloadOperation(extensionIdentifier) { answer($0) }
        }
        let error: Error?
        switch outcome {
        case .answered(let reloadError): error = reloadError
        case .timedOut: error = ReloadError.timedOut
        }
        return ReloadResult(
            extensionIdentifier: extensionIdentifier,
            success: error == nil,
            error: error,
            duration: Date().timeIntervalSince(start)
        )
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
/// Shared with `SystemContentBlockerStateProvider`, which races its state query the same way.
nonisolated final class ResumeOnce: @unchecked Sendable {
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
