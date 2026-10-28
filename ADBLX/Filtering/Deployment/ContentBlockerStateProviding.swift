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
    nonisolated init() {}

    nonisolated func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState {
        await withCheckedContinuation { continuation in
            SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: extensionIdentifier) { state, error in
                if let error {
                    continuation.resume(returning: .unavailable(error.localizedDescription))
                } else if let state {
                    continuation.resume(returning: state.isEnabled ? .enabled : .disabled)
                } else {
                    continuation.resume(returning: .unavailable("No state returned"))
                }
            }
        }
    }
}
