// ADBLX/Filtering/Deployment/ContentBlockerStateProviding.swift
import Foundation
import SafariServices
import os

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
/// The app uses one instance, from `AppCompositionRoot.makeContentBlockerStateProvider()`.
final class SystemContentBlockerStateProvider: ContentBlockerStateProviding, @unchecked Sendable {
    /// Calls back with whether the blocker is enabled, or an error. The real one wraps
    /// `SFContentBlockerManager`; tests pass one that never calls back.
    typealias StateOperation = @Sendable (
        _ extensionIdentifier: String, _ completion: @escaping @Sendable (_ isEnabled: Bool?, _ error: Error?) -> Void
    ) -> Void

    private let timeoutSeconds: Int
    private let gate: ContentBlockerCallGate
    private let stateOperation: StateOperation
    /// The check in progress for each blocker, and how many callers are waiting on it.
    private let inFlight = OSAllocatedUnfairLock(
        initialState: [String: (check: Task<ContentBlockerSettingsState, Never>, callers: Int)]()
    )

    nonisolated init(
        timeoutSeconds: Int = 5,
        gate: ContentBlockerCallGate = .shared,
        stateOperation: @escaping StateOperation = { identifier, completion in
            SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: identifier) { state, error in
                completion(state?.isEnabled, error)
            }
        }
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.gate = gate
        self.stateOperation = stateOperation
    }

    /// Callers currently waiting for a check of `identifier`. Lets tests observe them without timing.
    nonisolated func callers(waitingOn identifier: String) -> Int {
        inFlight.withLock { $0[identifier]?.callers ?? 0 }
    }

    /// Concurrent checks of the same blocker share one call. A check that starts after it
    /// finishes makes a new one, so an answer is never older than the call it came from.
    ///
    /// Never waits past `timeoutSeconds` once the call starts: `getStateOfContentBlocker` can drop
    /// its completion without calling it, and a timeout counts as state unknown (`.unavailable`).
    nonisolated func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState {
        let shared = inFlight.withLock { checks in
            if var entry = checks[extensionIdentifier] {
                entry.callers += 1
                checks[extensionIdentifier] = entry
                return entry.check
            }
            let check = Task { [self] in
                let state = await check(extensionIdentifier)
                inFlight.withLock { $0[extensionIdentifier] = nil }
                return state
            }
            checks[extensionIdentifier] = (check, 1)
            return check
        }
        return await shared.value
    }

    private nonisolated func check(_ extensionIdentifier: String) async -> ContentBlockerSettingsState {
        let stateOperation = self.stateOperation
        let outcome: ContentBlockerCallGate.Outcome<(isEnabled: Bool?, error: Error?)> = await gate.call(
            timeout: .seconds(timeoutSeconds)
        ) { answer in
            stateOperation(extensionIdentifier) { isEnabled, error in answer((isEnabled, error)) }
        }
        switch outcome {
        case .timedOut:
            return .unavailable("Timed out after \(timeoutSeconds) s")
        case .answered((_, let error?)):
            return .unavailable(error.localizedDescription)
        case .answered((let isEnabled?, nil)):
            return isEnabled ? .enabled : .disabled
        case .answered((nil, nil)):
            return .unavailable("No state returned")
        }
    }
}
