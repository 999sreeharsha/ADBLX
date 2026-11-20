// ADBLX/Filtering/Deployment/ContentBlockerStateProviding.swift
import Foundation
import SafariServices

/// Represents the observed system state of a Safari Content Blocker extension in iOS Settings.
enum ContentBlockerSettingsState: Equatable, Sendable {
    case enabled
    case disabled
    case unavailable(String)
}

/// Metadata descriptor for a Content Blocker extension target, including whether it participates
/// in the master Safari Protection status aggregation for the current deployment sprint.
struct ContentBlockerDescriptor: Sendable, Equatable {
    let category: FilterCategoryID
    let extensionIdentifier: String
    let participatesInProtectionStatus: Bool

    nonisolated init(
        category: FilterCategoryID,
        extensionIdentifier: String,
        participatesInProtectionStatus: Bool = true
    ) {
        self.category = category
        self.extensionIdentifier = extensionIdentifier
        self.participatesInProtectionStatus = participatesInProtectionStatus
    }
}

/// Protocol abstracting `SFContentBlockerManager.getStateOfContentBlocker` queries.
nonisolated protocol ContentBlockerStateProviding: Sendable {
    nonisolated func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState
}

/// Production implementation querying `SFContentBlockerManager.getStateOfContentBlocker`.
final class SystemContentBlockerStateProvider: ContentBlockerStateProviding, @unchecked Sendable {
    /// Calls back with whether the blocker is enabled, or an error. The real one wraps
    /// `SFContentBlockerManager`; tests pass one that never calls back.
    typealias StateOperation = @Sendable (
        _ extensionIdentifier: String, _ completion: @escaping @Sendable (_ isEnabled: Bool?, _ error: Error?) -> Void
    ) -> Void

    private let timeoutSeconds: Int
    private let stateOperation: StateOperation

    nonisolated init(
        timeoutSeconds: Int = 5,
        stateOperation: @escaping StateOperation = { identifier, completion in
            SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: identifier) { state, error in
                completion(state?.isEnabled, error)
            }
        }
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.stateOperation = stateOperation
    }

    /// Never waits past `timeoutSeconds`: `getStateOfContentBlocker` can drop its completion
    /// without calling it, and a timeout counts as state unknown (`.unavailable`). Same race as
    /// `ReloadCoordinator`: an unstructured timeout Task, and `ResumeOnce` so only one side resumes.
    nonisolated func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState {
        let timeoutSeconds = self.timeoutSeconds
        return await withCheckedContinuation { (continuation: CheckedContinuation<ContentBlockerSettingsState, Never>) in
            let resumeGuard = ResumeOnce()

            stateOperation(extensionIdentifier) { isEnabled, error in
                guard resumeGuard.markAndCheckFirst() else { return }
                if let error {
                    continuation.resume(returning: .unavailable(error.localizedDescription))
                } else if let isEnabled {
                    continuation.resume(returning: isEnabled ? .enabled : .disabled)
                } else {
                    continuation.resume(returning: .unavailable("No state returned"))
                }
            }

            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard resumeGuard.markAndCheckFirst() else { return }
                continuation.resume(returning: .unavailable("Timed out after \(timeoutSeconds) s"))
            }
        }
    }
}
