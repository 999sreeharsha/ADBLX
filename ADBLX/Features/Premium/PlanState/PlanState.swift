import Foundation

/// How a user's Premium came to be, for display. Entitlement *enforcement* never branches on
/// this — it asks `EntitlementService`.
nonisolated enum PremiumKind: Equatable, Sendable {
    case subscription
    case lifetime
}

/// The single derived answer to "what plan is this user on?". Home, Settings and Premium all
/// render from this; no view computes its own trial/entitlement status.
nonisolated enum PlanState: Equatable, Sendable {
    case premium(PremiumKind)
    case trial(daysRemaining: Int, endsAt: Date)
    /// The 15-day trial ended and nothing was purchased. Persists after the user taps
    /// "Continue free": the choice suppresses the full-screen, not this fact.
    case trialExpired(endedAt: Date)
    /// Never started a trial, nothing purchased.
    case free

    /// Whether Premium features are available right now.
    var isEntitled: Bool {
        switch self {
        case .premium, .trial: return true
        case .trialExpired, .free: return false
        }
    }

    /// 3 days or fewer remain in an active trial.
    var isTrialEndingSoon: Bool {
        if case .trial(let daysRemaining, _) = self { return daysRemaining <= 3 }
        return false
    }
}
