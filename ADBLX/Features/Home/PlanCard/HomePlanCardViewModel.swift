import Foundation
import Observation

/// Feeds the plan area on Home. `PlanState` comes in as an argument, so this holds no copy of
/// the trial or entitlement status and is tested without `PlanStateModel`.
@MainActor
@Observable
final class HomePlanCardViewModel {
    private(set) var presentation: HomePlanPresentation = .unresolved
    private(set) var breakdown: ProtectionBreakdown?
    private(set) var prices = PlanPrices()

    @ObservationIgnored private let dismissalStore: PlanCardDismissalStoring
    @ObservationIgnored private let stateProvider: ContentBlockerStateProviding
    @ObservationIgnored private let extensionIdentifiers: GroupExtensionIdentifiers
    @ObservationIgnored private let subscriptionService: SubscriptionService
    @ObservationIgnored private let dnsAvailable: Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Bumped by every refresh and dismissal, so details that arrive after a newer one are dropped.
    @ObservationIgnored private var generation = 0

    init(
        dismissalStore: PlanCardDismissalStoring = UserDefaultsPlanCardDismissalStore(),
        stateProvider: ContentBlockerStateProviding,
        extensionIdentifiers: GroupExtensionIdentifiers,
        subscriptionService: SubscriptionService,
        dnsAvailable: Bool = BuildFeatures.dnsProtection,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dismissalStore = dismissalStore
        self.stateProvider = stateProvider
        self.extensionIdentifiers = extensionIdentifiers
        self.subscriptionService = subscriptionService
        self.dnsAvailable = dnsAvailable
        self.now = now
    }

    /// The card shows at once. Its breakdown (which waits for blocker checks in
    /// `ContentBlockerCallGate`) and prices (from the store) fill in when they arrive.
    func refresh(plan: PlanState, isResolved: Bool) async {
        generation += 1
        let current = generation
        var dismissals = dismissalStore.load()
        let result = dismissals.presentation(for: plan, isResolved: isResolved, now: now())
        // Evaluating may have used up a re-expansion, so keep what changed.
        if dismissals != dismissalStore.load() { dismissalStore.save(dismissals) }

        guard result == .protectionCard || result == .freePlanCard else {
            presentation = result
            breakdown = nil
            return
        }
        // A different card drops the old breakdown; the same card keeps it until the new one arrives.
        if presentation != result { breakdown = nil }
        presentation = result

        async let safariEnabled = isSafariProtectionEnabled()
        async let status = subscriptionService.fetchStatus()
        let enabled = await safariEnabled
        if current == generation {
            breakdown = ProtectionBreakdown.make(
                plan: plan, safariProtectionEnabled: enabled, dnsAvailable: dnsAvailable
            )
        }
        let fetched = await status
        if current == generation {
            prices = PlanPrices(plans: fetched.plans)
        }
    }

    /// "Later" on the trial card, or the dismiss control on the protection card.
    func dismiss(plan: PlanState) {
        generation += 1
        var dismissals = dismissalStore.load()
        switch plan {
        case .trial: dismissals.trialEnding.dismiss(at: now())
        case .trialExpired, .free: dismissals.protection.dismiss(at: now())
        case .premium: return
        }
        dismissalStore.save(dismissals)
        presentation = dismissals.presentation(for: plan, isResolved: true, now: now())
        breakdown = nil
    }

    private func isSafariProtectionEnabled() async -> Bool {
        async let ads = stateProvider.state(of: extensionIdentifiers[.ads])
        async let privacy = stateProvider.state(of: extensionIdentifiers[.privacy])
        let (adsState, privacyState) = await (ads, privacy)
        return adsState == .enabled && privacyState == .enabled
    }
}
