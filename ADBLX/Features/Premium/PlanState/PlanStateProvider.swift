import Foundation

/// Derives `PlanState` from StoreKit entitlements and the trial. An actor, so the Keychain
/// read and StoreKit lookup never run on the main thread; the clock is injected so expiry
/// can be tested without waiting 15 days.
actor PlanStateProvider {
    private let trial: TrialSource
    private let paid: PaidEntitlementSource
    private let now: @Sendable () -> Date

    init(trial: TrialSource, paid: PaidEntitlementSource, now: @escaping @Sendable () -> Date = { Date() }) {
        self.trial = trial
        self.paid = paid
        self.now = now
    }

    func current() async -> PlanState {
        if let kind = await paid.activePremiumKind() {
            return .premium(kind)
        }
        switch await trial.snapshot(at: now()) {
        case .active(let endsAt, let daysRemaining):
            return .trial(daysRemaining: daysRemaining, endsAt: endsAt)
        case .expired(let endedAt):
            return .trialExpired(endedAt: endedAt)
        case .notStarted:
            return .free
        }
    }
}
