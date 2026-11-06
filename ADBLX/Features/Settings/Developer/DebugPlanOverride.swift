#if DEBUG
import Foundation

/// A fixed `PlanState` the Developer screen can force, to see Home and Premium in each plan
/// without waiting out a trial or buying anything. It changes what is displayed only:
/// entitlement, the reconciler and the extensions still follow the real state. Compiled out
/// of release builds.
enum DebugPlanOverride: String, CaseIterable, Identifiable {
    case premiumSubscription
    case premiumLifetime
    case trialNineDays
    case trialTwoDays
    case trialExpired
    case free

    var id: String { rawValue }

    var label: String {
        switch self {
        case .premiumSubscription: return "Premium (subscription)"
        case .premiumLifetime: return "Premium (lifetime)"
        case .trialNineDays: return "Trial, 9 days left"
        case .trialTwoDays: return "Trial, 2 days left"
        case .trialExpired: return "Trial expired"
        case .free: return "Free (no trial)"
        }
    }

    func state(now: Date = Date()) -> PlanState {
        let day: TimeInterval = 24 * 60 * 60
        switch self {
        case .premiumSubscription: return .premium(.subscription)
        case .premiumLifetime: return .premium(.lifetime)
        case .trialNineDays: return .trial(daysRemaining: 9, endsAt: now.addingTimeInterval(9 * day))
        case .trialTwoDays: return .trial(daysRemaining: 2, endsAt: now.addingTimeInterval(2 * day))
        case .trialExpired: return .trialExpired(endedAt: now.addingTimeInterval(-day))
        case .free: return .free
        }
    }
}
#endif
