import Foundation

/// What the plan area at the top of Home shows. Derived from `PlanState`; the view renders it
/// and decides nothing itself.
nonisolated enum HomePlanPresentation: Equatable, Sendable {
    /// The plan has not been derived yet. Shows a neutral placeholder, never a plan-specific claim.
    case unresolved
    /// Nothing to say (a paying user).
    case hidden
    case trialChip(daysRemaining: Int)
    case trialEndingCard(endsAt: Date)
    /// After the trial ended: what is still on and what turned off.
    case protectionCard
    /// Never trialled and not paying: the same breakdown without any claim about a trial.
    case freePlanCard
    /// Either card after it was dismissed.
    case freeChip
}

/// Whether one dismissible card is collapsed. A dismissed card re-expands once 7 days have
/// passed, at most 3 times in all, so a user who keeps dismissing it stops being asked.
nonisolated struct PlanCardDismissal: Codable, Equatable, Sendable {
    static let reExpandInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maxReExpansions = 3

    private(set) var dismissedAt: Date?
    private(set) var reExpansions = 0

    mutating func dismiss(at now: Date) {
        dismissedAt = now
    }

    /// Re-expanding consumes one of the 3, so call this once per evaluation and persist the
    /// result. A clock moved backwards never re-expands.
    mutating func isCollapsed(at now: Date) -> Bool {
        guard let dismissedAt else { return false }
        guard reExpansions < Self.maxReExpansions,
              now.timeIntervalSince(dismissedAt) >= Self.reExpandInterval else { return true }
        self.dismissedAt = nil
        reExpansions += 1
        return false
    }
}

/// The trial-ending card and the protection card are dismissed independently.
nonisolated struct HomePlanDismissals: Codable, Equatable, Sendable {
    var trialEnding = PlanCardDismissal()
    var protection = PlanCardDismissal()

    mutating func presentation(for plan: PlanState, isResolved: Bool, now: Date) -> HomePlanPresentation {
        guard isResolved else { return .unresolved }
        switch plan {
        case .premium:
            return .hidden
        case .trial(let daysRemaining, let endsAt):
            guard plan.isTrialEndingSoon, !trialEnding.isCollapsed(at: now) else {
                return .trialChip(daysRemaining: daysRemaining)
            }
            return .trialEndingCard(endsAt: endsAt)
        case .trialExpired:
            return protection.isCollapsed(at: now) ? .freeChip : .protectionCard
        case .free:
            return protection.isCollapsed(at: now) ? .freeChip : .freePlanCard
        }
    }
}

nonisolated protocol PlanCardDismissalStoring: Sendable {
    func load() -> HomePlanDismissals
    func save(_ dismissals: HomePlanDismissals)
}

nonisolated final class UserDefaultsPlanCardDismissalStore: PlanCardDismissalStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "home.planCard.dismissals"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> HomePlanDismissals {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(HomePlanDismissals.self, from: $0) }
            ?? HomePlanDismissals()
    }

    func save(_ dismissals: HomePlanDismissals) {
        defaults.set(try? JSONEncoder().encode(dismissals), forKey: key)
    }
}

/// What is on and off for the user's plan, built from the plan and the real extension status
/// rather than listed as fixed claims.
nonisolated struct ProtectionBreakdown: Equatable, Sendable {
    enum Item: CaseIterable, Equatable, Sendable {
        case safariAdsTrackers
        case allowlist
        case filterUpdates
        case youtubeAds
        case cookieBanners
        case indianSites
        case systemWideBlocking
        case iCloudSync

        /// Needs Premium; the others work on the free plan.
        var requiresPremium: Bool {
            switch self {
            case .safariAdsTrackers, .allowlist, .filterUpdates: return false
            case .youtubeAds, .cookieBanners, .indianSites, .systemWideBlocking, .iCloudSync: return true
            }
        }

        var titleKey: String {
            switch self {
            case .safariAdsTrackers: return "home.plan.item.safariAdsTrackers"
            case .allowlist: return "home.plan.item.allowlist"
            case .filterUpdates: return "home.plan.item.filterUpdates"
            case .youtubeAds: return "home.plan.item.youtubeAds"
            case .cookieBanners: return "home.plan.item.cookieBanners"
            case .indianSites: return "home.plan.item.indianSites"
            case .systemWideBlocking: return "home.plan.item.systemWideBlocking"
            case .iCloudSync: return "home.plan.item.iCloudSync"
            }
        }

        var title: String { String(localized: String.LocalizationValue(titleKey)) }
    }

    let stillOn: [Item]
    let turnedOff: [Item]

    /// - Parameters:
    ///   - safariProtectionEnabled: both the Ads and Privacy Safari extensions are on in Settings.
    ///   - dnsAvailable: this build ships DNS Protection; when it doesn't, "system-wide blocking"
    ///     is not mentioned at all.
    static func make(plan: PlanState, safariProtectionEnabled: Bool, dnsAvailable: Bool) -> ProtectionBreakdown {
        var on: [Item] = []
        var off: [Item] = []
        for item in Item.allCases where dnsAvailable || item != .systemWideBlocking {
            let isOn = item.requiresPremium
                ? plan.isEntitled
                : (item != .safariAdsTrackers || safariProtectionEnabled)
            if isOn { on.append(item) } else { off.append(item) }
        }
        return ProtectionBreakdown(stillOn: on, turnedOff: off)
    }
}

/// The store's display prices for the two plans the card shows. A plan the store did not
/// return stays nil: the card never falls back to a number of its own.
nonisolated struct PlanPrices: Equatable, Sendable {
    var annual: String?
    var lifetime: String?

    init() {}

    init(plans: [SubscriptionPlan]) {
        annual = plans.first { $0.id == "annual" }?.priceDescription
        lifetime = plans.first { $0.id == "lifetime" }?.priceDescription
    }

    /// "Annual … · Lifetime …" from whichever prices the store returned, or nil when it
    /// returned neither, so the button shows no price rather than a made-up one.
    var summaryLine: String? {
        let parts = [
            annual.map { String(format: String(localized: "home.plan.price.annual"), $0) },
            lifetime.map { String(format: String(localized: "home.plan.price.lifetime"), $0) }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

nonisolated enum HomePlanCardStrings {
    static let allKeys = [
        "home.plan.chip.trial.one", "home.plan.chip.trial.other", "home.plan.chip.free",
        "home.plan.trialEnding.title", "home.plan.seePlans", "home.plan.later", "home.plan.dismiss",
        "home.plan.free.title", "home.plan.free.subtitle",
        "home.plan.protection.title", "home.plan.protection.stillOn", "home.plan.protection.turnedOff",
        "home.plan.getPremium", "home.plan.price.annual", "home.plan.price.lifetime",
        "home.plan.status.on", "home.plan.status.off", "home.plan.unresolved"
    ] + ProtectionBreakdown.Item.allCases.map(\.titleKey)

    static func trialChip(daysRemaining: Int) -> String {
        daysRemaining == 1
            ? String(localized: "home.plan.chip.trial.one")
            : String(format: String(localized: "home.plan.chip.trial.other"), daysRemaining)
    }
}
