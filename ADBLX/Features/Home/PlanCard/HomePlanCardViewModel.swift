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

    func refresh(plan: PlanState, isResolved: Bool) async {
        var dismissals = dismissalStore.load()
        let result = dismissals.presentation(for: plan, isResolved: isResolved, now: now())
        // Evaluating may have used up a re-expansion, so keep what changed.
        if dismissals != dismissalStore.load() { dismissalStore.save(dismissals) }

        guard result == .protectionCard || result == .freePlanCard else {
            presentation = result
            breakdown = nil
            return
        }
        async let safariEnabled = isSafariProtectionEnabled()
        async let status = subscriptionService.fetchStatus()
        let (enabled, fetched) = await (safariEnabled, status)
        breakdown = ProtectionBreakdown.make(plan: plan, safariProtectionEnabled: enabled, dnsAvailable: dnsAvailable)
        prices = PlanPrices(plans: fetched.plans)
        presentation = result
    }

    /// "Later" on the trial card, or the dismiss control on the protection card.
    func dismiss(plan: PlanState) {
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
