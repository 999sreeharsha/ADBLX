import Foundation

/// User-facing text for `PlanState`. Kept out of views so every surface words a plan the
/// same way and the wording is unit-tested.
nonisolated enum PlanStateDisplay {
    static func planRowText(for state: PlanState) -> String {
        switch state {
        case .premium(.subscription):
            return String(localized: "settings.plan.premium")
        case .premium(.lifetime):
            return String(localized: "settings.plan.lifetime")
        case .trial(let daysRemaining, _):
            return daysRemaining == 1
                ? String(localized: "settings.plan.trial.one")
                : String(format: String(localized: "settings.plan.trial.other"), daysRemaining)
        case .trialExpired:
            return String(localized: "settings.plan.trialEnded")
        case .free:
            return String(localized: "settings.plan.free")
        }
    }
}
