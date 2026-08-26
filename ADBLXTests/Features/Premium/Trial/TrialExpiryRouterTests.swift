// ADBLXTests/Features/Premium/Trial/TrialExpiryRouterTests.swift
import Foundation
import Testing
@testable import ADBLX

@Suite("TrialExpiryRouter", .serialized)
@MainActor
struct TrialExpiryRouterTests {
    @Test("Active trial routes to .none")
    func activeTrialRoutesToNone() async {
        let trialStore = InMemoryTrialStore()
        let trialManager = TrialManager(store: trialStore)
        _ = await trialManager.activateTrial(at: Date())

        let mockEntitlement = MockSubscriptionService(state: .trial(expiresAt: Date().addingTimeInterval(15 * 86400)))
        let decisionStore = InMemoryTrialDecisionStore(chosen: false)

        let router = TrialExpiryRouter(
            entitlementService: mockEntitlement,
            trialManager: trialManager,
            decisionStore: decisionStore
        )

        await router.evaluateRoute()
        #expect(router.currentRoute == .none)
    }

    @Test("Paid subscription routes to .none even if trial record is expired")
    func paidSubscriptionRoutesToNone() async {
        let pastDate = Date().addingTimeInterval(-20 * 86400)
        let record = TrialRecord(
            activatedAt: pastDate,
            duration: 15 * 86400,
            lastObservedDate: pastDate,
            isExpired: true
        )
        let trialStore = InMemoryTrialStore(record: record)
        let trialManager = TrialManager(store: trialStore)

        let mockEntitlement = MockSubscriptionService(state: .annual(expiresAt: Date().addingTimeInterval(365 * 86400)))
        let decisionStore = InMemoryTrialDecisionStore(chosen: false)

        let router = TrialExpiryRouter(
            entitlementService: mockEntitlement,
            trialManager: trialManager,
            decisionStore: decisionStore
        )

        await router.evaluateRoute()
        #expect(router.currentRoute == .none)
    }

    @Test("Unstarted trial (.notStarted) routes to .none")
    func unstartedTrialRoutesToNone() async {
        let trialStore = InMemoryTrialStore()
        let trialManager = TrialManager(store: trialStore)

        let mockEntitlement = MockSubscriptionService(state: .free)
        let decisionStore = InMemoryTrialDecisionStore(chosen: false)

        let router = TrialExpiryRouter(
            entitlementService: mockEntitlement,
            trialManager: trialManager,
            decisionStore: decisionStore
        )

        await router.evaluateRoute()
        #expect(router.currentRoute == .none)
    }

    @Test("Expired trial with chosenFreeTier = false routes to .showExpiredDecision")
    func expiredTrialRoutesToShowDecision() async {
        let pastDate = Date().addingTimeInterval(-20 * 86400)
        let record = TrialRecord(
            activatedAt: pastDate,
            duration: 15 * 86400,
            lastObservedDate: pastDate,
            isExpired: true
        )
        let trialStore = InMemoryTrialStore(record: record)
        let trialManager = TrialManager(store: trialStore)

        let mockEntitlement = MockSubscriptionService(state: .free)
        let decisionStore = InMemoryTrialDecisionStore(chosen: false)

        let router = TrialExpiryRouter(
            entitlementService: mockEntitlement,
            trialManager: trialManager,
            decisionStore: decisionStore
        )

        await router.evaluateRoute()
        #expect(router.currentRoute == .showExpiredDecision)
    }

    @Test("Expired trial with chosenFreeTier = true routes to .none")
    func expiredTrialWithFreeChosenRoutesToNone() async {
        let pastDate = Date().addingTimeInterval(-20 * 86400)
        let record = TrialRecord(
            activatedAt: pastDate,
            duration: 15 * 86400,
            lastObservedDate: pastDate,
            isExpired: true
        )
        let trialStore = InMemoryTrialStore(record: record)
        let trialManager = TrialManager(store: trialStore)

        let mockEntitlement = MockSubscriptionService(state: .free)
        let decisionStore = InMemoryTrialDecisionStore(chosen: true)

        let router = TrialExpiryRouter(
            entitlementService: mockEntitlement,
            trialManager: trialManager,
            decisionStore: decisionStore
        )

        await router.evaluateRoute()
        #expect(router.currentRoute == .none)
    }

    @Test("Entitlement change to paid automatically clears .showExpiredDecision")
    func purchaseClearsDecisionRoute() async throws {
        let pastDate = Date().addingTimeInterval(-20 * 86400)
        let record = TrialRecord(
            activatedAt: pastDate,
            duration: 15 * 86400,
            lastObservedDate: pastDate,
            isExpired: true
        )
        let trialStore = InMemoryTrialStore(record: record)
        let trialManager = TrialManager(store: trialStore)

        let mockEntitlement = MockSubscriptionService(state: .free)
        let decisionStore = InMemoryTrialDecisionStore(chosen: false)

        let router = TrialExpiryRouter(
            entitlementService: mockEntitlement,
            trialManager: trialManager,
            decisionStore: decisionStore
        )

        await router.evaluateRoute()
        #expect(router.currentRoute == .showExpiredDecision)

        mockEntitlement.updateState(.monthly(expiresAt: Date().addingTimeInterval(30 * 86400)))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(router.currentRoute == .none)
    }
}
