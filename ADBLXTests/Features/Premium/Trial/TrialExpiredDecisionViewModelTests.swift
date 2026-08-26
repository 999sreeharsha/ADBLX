// ADBLXTests/Features/Premium/Trial/TrialExpiredDecisionViewModelTests.swift
import Foundation
import Testing
@testable import ADBLX

@Suite("TrialExpiredDecisionViewModel", .serialized)
@MainActor
struct TrialExpiredDecisionViewModelTests {
    @Test("continueWithFree sets decision flag, cancels notifications, and calls onDismiss")
    func continueWithFreeDismisses() async {
        let decisionStore = InMemoryTrialDecisionStore(chosen: false)
        let scheduler = MockTrialNotificationScheduler()
        let mockEntitlement = MockSubscriptionService(state: .free)
        var dismissed = false

        let viewModel = TrialExpiredDecisionViewModel(
            decisionStore: decisionStore,
            notificationScheduler: scheduler,
            entitlementService: mockEntitlement,
            onDismiss: { dismissed = true }
        )

        await viewModel.continueWithFree()

        #expect(await decisionStore.hasChosenFreeTier() == true)
        #expect(scheduler.cancelledCount == 1)
        #expect(dismissed == true)
    }

    @Test("viewPremiumPlans opens paywall sheet; closing sheet without purchase does NOT dismiss decision")
    func viewPremiumPlansAndDismissWithoutPurchase() {
        let decisionStore = InMemoryTrialDecisionStore(chosen: false)
        let scheduler = MockTrialNotificationScheduler()
        let mockEntitlement = MockSubscriptionService(state: .free)
        var dismissed = false

        let viewModel = TrialExpiredDecisionViewModel(
            decisionStore: decisionStore,
            notificationScheduler: scheduler,
            entitlementService: mockEntitlement,
            onDismiss: { dismissed = true }
        )

        #expect(viewModel.showPaywallSheet == false)

        viewModel.viewPremiumPlans()
        #expect(viewModel.showPaywallSheet == true)
        #expect(dismissed == false)

        // Simulate user dismissing the paywall sheet without buying
        viewModel.showPaywallSheet = false
        #expect(dismissed == false)
    }

    @Test("Successful purchase from paywall sheet updates entitlement and dismisses decision view")
    func purchaseDismissesDecisionView() async throws {
        let decisionStore = InMemoryTrialDecisionStore(chosen: false)
        let scheduler = MockTrialNotificationScheduler()
        let mockEntitlement = MockSubscriptionService(state: .free)
        var dismissed = false

        let viewModel = TrialExpiredDecisionViewModel(
            decisionStore: decisionStore,
            notificationScheduler: scheduler,
            entitlementService: mockEntitlement,
            onDismiss: { dismissed = true }
        )

        viewModel.viewPremiumPlans()
        #expect(viewModel.showPaywallSheet == true)

        // Entitlement updates upon purchase
        mockEntitlement.updateState(.annual(expiresAt: Date().addingTimeInterval(365 * 86400)))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(viewModel.showPaywallSheet == false)
        #expect(dismissed == true)
    }
}
