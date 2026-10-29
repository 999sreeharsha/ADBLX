import Foundation

nonisolated enum TrialSnapshot: Equatable, Sendable {
    case notStarted
    case active(endsAt: Date, daysRemaining: Int)
    case expired(endedAt: Date)
}

/// Where trial facts come from. Today: the app-managed Keychain trial. A future StoreKit /
/// zero-price-IAP trial (see docs/gotchas.md, "Trial is Keychain-only") swaps in by
/// conforming to this — nothing else in plan-state derivation changes.
nonisolated protocol TrialSource: Sendable {
    func snapshot(at date: Date) async -> TrialSnapshot
}

/// Adapts `TrialManager` (which already guards against the clock moving backwards via
/// `lastObservedDate`, and makes expiry sticky) to `TrialSource`.
nonisolated final class KeychainTrialSource: TrialSource, Sendable {
    private let manager: TrialManagerProtocol
    private let store: TrialStoreProtocol

    init(manager: TrialManagerProtocol, store: TrialStoreProtocol) {
        self.manager = manager
        self.store = store
    }

    func snapshot(at date: Date) async -> TrialSnapshot {
        switch await manager.status(at: date) {
        case .notStarted:
            return .notStarted
        case .active(let expiresAt, let daysRemaining):
            return .active(endsAt: expiresAt, daysRemaining: daysRemaining)
        case .expired:
            // `TrialStatus.expired` carries no date; the record does.
            return .expired(endedAt: store.loadRecord()?.expiresAt ?? date)
        }
    }
}

/// Whether the user holds a paid (non-trial) Premium entitlement right now.
nonisolated protocol PaidEntitlementSource: Sendable {
    func activePremiumKind() async -> PremiumKind?
}
