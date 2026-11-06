import Testing
import Foundation
@testable import ADBLX

private let day: TimeInterval = 24 * 60 * 60
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Home plan presentation")
struct HomePlanPresentationTests {
    private func present(
        _ plan: PlanState, resolved: Bool = true,
        dismissals: HomePlanDismissals = HomePlanDismissals(), now: Date = t0
    ) -> HomePlanPresentation {
        var copy = dismissals
        return copy.presentation(for: plan, isResolved: resolved, now: now)
    }

    @Test("nothing plan-specific shows until the plan is resolved")
    func unresolved() {
        #expect(present(.premium(.lifetime), resolved: false) == .unresolved)
        #expect(present(.trialExpired(endedAt: t0), resolved: false) == .unresolved)
    }

    @Test("a paying user sees nothing")
    func premiumHidden() {
        #expect(present(.premium(.subscription)) == .hidden)
        #expect(present(.premium(.lifetime)) == .hidden)
    }

    @Test("a trial with more than 3 days left is a small chip")
    func trialChip() {
        #expect(present(.trial(daysRemaining: 15, endsAt: t0)) == .trialChip(daysRemaining: 15))
        #expect(present(.trial(daysRemaining: 4, endsAt: t0)) == .trialChip(daysRemaining: 4))
    }

    @Test("a trial with 3 days or fewer left is a card with the end date")
    func trialEndingCard() {
        let endsAt = t0.addingTimeInterval(3 * day)
        #expect(present(.trial(daysRemaining: 3, endsAt: endsAt)) == .trialEndingCard(endsAt: endsAt))
        #expect(present(.trial(daysRemaining: 1, endsAt: endsAt)) == .trialEndingCard(endsAt: endsAt))
    }

    @Test("after the trial the protection card shows")
    func protectionCard() {
        #expect(present(.trialExpired(endedAt: t0)) == .protectionCard)
    }

    @Test("a user who never trialled gets the free plan card, not the trial-ended one")
    func freePlanCard() {
        #expect(present(.free) == .freePlanCard)
    }

    @Test("dismissing the free plan card collapses it to the free chip")
    func dismissFreePlanCard() {
        var dismissals = HomePlanDismissals()
        dismissals.protection.dismiss(at: t0)

        #expect(present(.free, dismissals: dismissals, now: t0.addingTimeInterval(day)) == .freeChip)
    }

    @Test("Later on the trial card collapses it to the trial chip")
    func laterCollapsesTrialCard() {
        var dismissals = HomePlanDismissals()
        dismissals.trialEnding.dismiss(at: t0)

        let shown = present(.trial(daysRemaining: 2, endsAt: t0), dismissals: dismissals, now: t0.addingTimeInterval(day))

        #expect(shown == .trialChip(daysRemaining: 2))
    }

    @Test("dismissing the protection card collapses it to the free chip")
    func dismissCollapsesProtectionCard() {
        var dismissals = HomePlanDismissals()
        dismissals.protection.dismiss(at: t0)

        #expect(present(.trialExpired(endedAt: t0), dismissals: dismissals, now: t0.addingTimeInterval(day)) == .freeChip)
    }

    @Test("the two cards are dismissed independently")
    func independentDismissals() {
        var dismissals = HomePlanDismissals()
        dismissals.protection.dismiss(at: t0)

        #expect(present(.trial(daysRemaining: 1, endsAt: t0), dismissals: dismissals) == .trialEndingCard(endsAt: t0))
    }
}

@Suite("Plan card dismissal")
struct PlanCardDismissalTests {
    /// `isCollapsed` mutates (re-expanding uses up one of 3), which `#expect` cannot do to a variable.
    private func collapsed(_ dismissal: PlanCardDismissal, at date: Date) -> Bool {
        var copy = dismissal
        return copy.isCollapsed(at: date)
    }

    @Test("a card that was never dismissed is expanded")
    func neverDismissed() {
        var dismissal = PlanCardDismissal()
        #expect(!collapsed(dismissal, at: t0))
    }

    @Test("a dismissed card stays collapsed for 7 days")
    func collapsedForSevenDays() {
        var dismissal = PlanCardDismissal()
        dismissal.dismiss(at: t0)

        #expect(collapsed(dismissal, at: t0))
        #expect(collapsed(dismissal, at: t0.addingTimeInterval(7 * day - 1)))
    }

    @Test("it re-expands after 7 days")
    func reExpandsAfterSevenDays() {
        var dismissal = PlanCardDismissal()
        dismissal.dismiss(at: t0)

        #expect(!collapsed(dismissal, at: t0.addingTimeInterval(7 * day)))
    }

    @Test("the fourth re-expansion is blocked")
    func fourthReExpansionBlocked() {
        var dismissal = PlanCardDismissal()
        var clock = t0
        for _ in 0..<3 {
            dismissal.dismiss(at: clock)
            clock = clock.addingTimeInterval(7 * day)
            #expect(!collapsed(dismissal, at: clock), "re-expansions 1 to 3 are allowed")
            _ = dismissal.isCollapsed(at: clock)
        }
        #expect(dismissal.reExpansions == 3)

        dismissal.dismiss(at: clock)

        #expect(collapsed(dismissal, at: clock.addingTimeInterval(7 * day)))
        #expect(collapsed(dismissal, at: clock.addingTimeInterval(30 * day)))
    }

    @Test("it re-expands at most 3 times, then stays collapsed")
    func atMostThreeReExpansions() {
        var dismissal = PlanCardDismissal()
        var clock = t0
        var expansions = 0
        for _ in 0..<6 {
            dismissal.dismiss(at: clock)
            clock = clock.addingTimeInterval(8 * day)
            if !dismissal.isCollapsed(at: clock) { expansions += 1 }
        }

        #expect(expansions == 3)
        dismissal.dismiss(at: clock)
        #expect(collapsed(dismissal, at: clock.addingTimeInterval(365 * day)))
    }

    @Test("a clock moved backwards does not re-expand it")
    func clockBackwards() {
        var dismissal = PlanCardDismissal()
        dismissal.dismiss(at: t0)

        #expect(collapsed(dismissal, at: t0.addingTimeInterval(-30 * day)))
    }

    @Test("it survives encoding")
    func codable() throws {
        var dismissal = PlanCardDismissal()
        dismissal.dismiss(at: t0)

        let decoded = try JSONDecoder().decode(PlanCardDismissal.self, from: try JSONEncoder().encode(dismissal))

        #expect(decoded == dismissal)
    }
}

@Suite("Protection breakdown")
struct ProtectionBreakdownTests {
    private let free = PlanState.trialExpired(endedAt: t0)

    @Test("on a free plan the free items are listed first, then what is off")
    func freeOrdering() {
        let breakdown = ProtectionBreakdown.make(plan: free, safariProtectionEnabled: true, dnsAvailable: true)

        #expect(breakdown.stillOn == [.safariAdsTrackers, .allowlist, .filterUpdates])
        #expect(breakdown.turnedOff == [.youtubeAds, .cookieBanners, .indianSites, .systemWideBlocking, .iCloudSync])
    }

    @Test("system-wide blocking is not listed in a build without DNS Protection")
    func noDNS() {
        let breakdown = ProtectionBreakdown.make(plan: free, safariProtectionEnabled: true, dnsAvailable: false)

        #expect(breakdown.turnedOff == [.youtubeAds, .cookieBanners, .indianSites, .iCloudSync])
    }

    @Test("Safari ads & trackers is not claimed while its extensions are off")
    func safariOff() {
        let breakdown = ProtectionBreakdown.make(plan: free, safariProtectionEnabled: false, dnsAvailable: false)

        #expect(breakdown.stillOn == [.allowlist, .filterUpdates])
        #expect(breakdown.turnedOff.first == .safariAdsTrackers)
    }

    @Test("a plan with Premium access has nothing turned off")
    func entitled() {
        let breakdown = ProtectionBreakdown.make(
            plan: .trial(daysRemaining: 9, endsAt: t0), safariProtectionEnabled: true, dnsAvailable: true
        )

        #expect(breakdown.turnedOff.isEmpty)
        #expect(breakdown.stillOn.count == 8)
    }

    @Test("system-wide blocking is never listed without DNS, whatever the plan", arguments: [
        PlanState.free, .trialExpired(endedAt: t0), .trial(daysRemaining: 9, endsAt: t0),
        .trial(daysRemaining: 1, endsAt: t0), .premium(.subscription), .premium(.lifetime)
    ])
    func neverWithoutDNS(plan: PlanState) {
        for safariOn in [true, false] {
            let breakdown = ProtectionBreakdown.make(plan: plan, safariProtectionEnabled: safariOn, dnsAvailable: false)
            #expect(!breakdown.stillOn.contains(.systemWideBlocking))
            #expect(!breakdown.turnedOff.contains(.systemWideBlocking))
            #expect(!(breakdown.stillOn + breakdown.turnedOff).map(\.title).contains("System-wide blocking"))
        }
    }

    @Test("each item has its own title")
    func titles() {
        let titles = ProtectionBreakdown.Item.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(ProtectionBreakdown.Item.cookieBanners.title == "Cookie banners & pop-ups")
        #expect(ProtectionBreakdown.Item.youtubeAds.title == "YouTube ads in Safari")
        #expect(ProtectionBreakdown.Item.safariAdsTrackers.title == "Safari ads & trackers")
    }
}

@Suite("Plan prices")
struct PlanPricesTests {
    private func plan(_ id: String, _ price: String) -> SubscriptionPlan {
        SubscriptionPlan(id: id, name: id, priceDescription: price, billingPeriodDescription: "", isCurrentPlan: false)
    }

    @Test("annual and lifetime come from the store's display prices")
    func fromPlans() {
        let prices = PlanPrices(plans: [plan("monthly", "₹99"), plan("annual", "₹799"), plan("lifetime", "₹1,999")])

        #expect(prices.annual == "₹799")
        #expect(prices.lifetime == "₹1,999")
    }

    @Test("the price line uses only prices the store returned")
    func summaryLine() {
        var both = PlanPrices()
        both.annual = "₹799"
        both.lifetime = "₹1,999"
        var annualOnly = PlanPrices()
        annualOnly.annual = "₹799"

        #expect(both.summaryLine == "Annual ₹799 · Lifetime ₹1,999")
        #expect(annualOnly.summaryLine == "Annual ₹799")
        #expect(PlanPrices().summaryLine == nil)
        #expect(PlanPrices(plans: []).summaryLine == nil)
    }

    @Test("a price the store did not return is nil, never a default")
    func missing() {
        let prices = PlanPrices(plans: [plan("monthly", "₹99")])

        #expect(prices.annual == nil)
        #expect(prices.lifetime == nil)
    }
}

@Suite("Home plan card model")
@MainActor
struct HomePlanCardViewModelTests {
    private let ids = GroupExtensionIdentifiers(
        ads: "ads", privacy: "privacy", annoyances: "annoyances", regional: "regional"
    )

    private func makeModel(
        store: InMemoryDismissalStore = InMemoryDismissalStore(),
        enabled: Set<String> = ["ads", "privacy"],
        plans: [SubscriptionPlan] = [],
        now: Date = t0
    ) -> HomePlanCardViewModel {
        HomePlanCardViewModel(
            dismissalStore: store,
            stateProvider: StubStateProvider(enabled: enabled),
            extensionIdentifiers: ids,
            subscriptionService: StubSubscriptions(plans: plans),
            dnsAvailable: false,
            now: { now }
        )
    }

    @Test("it starts unresolved")
    func startsUnresolved() {
        #expect(makeModel().presentation == .unresolved)
    }

    @Test("the protection card lists items from the plan and the extension status")
    func protectionCard() async throws {
        let model = makeModel(enabled: ["ads", "privacy"], plans: [
            SubscriptionPlan(id: "annual", name: "", priceDescription: "₹799", billingPeriodDescription: "", isCurrentPlan: false)
        ])

        await model.refresh(plan: .trialExpired(endedAt: t0), isResolved: true)

        #expect(model.presentation == .protectionCard)
        #expect(model.breakdown?.stillOn == [.safariAdsTrackers, .allowlist, .filterUpdates])
        #expect(model.prices.annual == "₹799")
        #expect(model.prices.lifetime == nil)
    }

    @Test("Safari ads & trackers needs both the Ads and Privacy extensions on")
    func needsBothExtensions() async {
        let model = makeModel(enabled: ["ads"])

        await model.refresh(plan: .free, isResolved: true)

        #expect(model.breakdown?.stillOn.contains(.safariAdsTrackers) == false)
    }

    @Test("dismissing collapses the card and the choice is remembered")
    func dismissPersists() async {
        let store = InMemoryDismissalStore()
        let first = makeModel(store: store)
        await first.refresh(plan: .trialExpired(endedAt: t0), isResolved: true)

        first.dismiss(plan: .trialExpired(endedAt: t0))

        #expect(first.presentation == .freeChip)
        let second = makeModel(store: store)
        await second.refresh(plan: .trialExpired(endedAt: t0), isResolved: true)
        #expect(second.presentation == .freeChip)
    }

    @Test("a re-expansion is counted once, not on every refresh")
    func reExpansionCountedOnce() async {
        let store = InMemoryDismissalStore()
        var seed = HomePlanDismissals()
        seed.protection.dismiss(at: t0)
        store.save(seed)
        let later = t0.addingTimeInterval(8 * day)

        for _ in 0..<5 {
            await makeModel(store: store, now: later).refresh(plan: .free, isResolved: true)
        }

        #expect(store.load().protection.reExpansions == 1)
    }

    @Test("with no prices from the store the model has no price line")
    func noPricesNoLine() async {
        let model = makeModel(plans: [])

        await model.refresh(plan: .trialExpired(endedAt: t0), isResolved: true)

        #expect(model.presentation == .protectionCard)
        #expect(model.prices.summaryLine == nil)
    }

    @Test("a build without DNS never lists system-wide blocking on either card", arguments: [
        PlanState.free, .trialExpired(endedAt: t0)
    ])
    func noSystemWideCard(plan: PlanState) async {
        let model = makeModel()

        await model.refresh(plan: plan, isResolved: true)

        let items = (model.breakdown?.stillOn ?? []) + (model.breakdown?.turnedOff ?? [])
        #expect(!items.isEmpty)
        #expect(!items.contains(.systemWideBlocking))
    }

    @Test("a paying user gets no card and no work is done for it")
    func premiumHidden() async {
        let model = makeModel()
        await model.refresh(plan: .premium(.lifetime), isResolved: true)
        #expect(model.presentation == .hidden)
        #expect(model.breakdown == nil)
    }
}

@Suite("Home plan card strings")
struct HomePlanCardStringsTests {
    @Test("every key has English text, not the key itself")
    func keysResolve() {
        for key in HomePlanCardStrings.allKeys {
            let value = String(localized: String.LocalizationValue(key))
            #expect(value != key, "\(key) has no translation")
        }
    }

    @Test("copy says cookie banners & pop-ups and never claims to reject cookies")
    func copy() {
        let all = HomePlanCardStrings.allKeys.map { String(localized: String.LocalizationValue($0)) }
        #expect(all.contains("Cookie banners & pop-ups"))
        #expect(!all.contains { $0.localizedCaseInsensitiveContains("reject") })
        #expect(!all.contains { $0.localizedCaseInsensitiveContains("we blocked") })
    }

    @Test("the free plan card says nothing about a trial ending or ended")
    func freeCardCopy() {
        let title = String(localized: "home.plan.free.title")
        let subtitle = String(localized: "home.plan.free.subtitle")
        #expect(title == "Free plan")
        #expect(subtitle == "Get more with Premium")
        #expect(!(title + subtitle).localizedCaseInsensitiveContains("trial"))
    }

    @Test("the trial chip reads naturally for one day and for many")
    func trialChipText() {
        #expect(HomePlanCardStrings.trialChip(daysRemaining: 1) == "Premium trial · 1 day left")
        #expect(HomePlanCardStrings.trialChip(daysRemaining: 9) == "Premium trial · 9 days left")
    }
}

nonisolated final class InMemoryDismissalStore: PlanCardDismissalStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value = HomePlanDismissals()
    func load() -> HomePlanDismissals { lock.withLock { value } }
    func save(_ dismissals: HomePlanDismissals) { lock.withLock { value = dismissals } }
}

private nonisolated struct StubStateProvider: ContentBlockerStateProviding {
    let enabled: Set<String>
    func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState {
        enabled.contains(extensionIdentifier) ? .enabled : .disabled
    }
}

private struct StubSubscriptions: SubscriptionService {
    let plans: [SubscriptionPlan]
    func fetchStatus() async -> SubscriptionStatus { SubscriptionStatus(isPremium: false, plans: plans) }
    func purchase(_ planID: String) async throws -> Bool { false }
    func restorePurchases() async throws {}
}
