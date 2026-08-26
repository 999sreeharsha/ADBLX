// ADBLXTests/Features/Premium/Trial/TrialEntitlementIntegrationTests.swift
import Foundation
import Testing
@testable import ADBLX

@Suite("TrialEntitlementIntegration")
struct TrialEntitlementIntegrationTests {
    @Test("Unactivated trial yields .free state")
    func unactivatedTrialYieldsFree() async {
        let store = InMemoryTrialStore()
        let trialManager = TrialManager(store: store)
        let service = StoreKitSubscriptionService(trialManager: trialManager)

        let state = await service.refreshEntitlements()
        #expect(state == .free)
        let isEntitled = await service.isPremiumEntitled()
        #expect(isEntitled == false)
    }

    @Test("Activating trial transitions entitlement to .trial and broadcasts update")
    func activatingTrialTransitionsEntitlement() async {
        let store = InMemoryTrialStore()
        let trialManager = TrialManager(store: store)
        let service = StoreKitSubscriptionService(trialManager: trialManager)

        var stream = await service.stateUpdates().makeAsyncIterator()
        let initial = await stream.next()
        #expect(initial == .free)

        let now = Date()
        let trialStatus = await trialManager.activateTrial(at: now)
        guard case .active(let expiresAt, _) = trialStatus else {
            Issue.record("Expected .active trial status")
            return
        }

        let updatedState = await service.refreshEntitlements()
        #expect(updatedState == .trial(expiresAt: expiresAt))
        #expect(await service.isPremiumEntitled() == true)

        let nextState = await stream.next()
        #expect(nextState == .trial(expiresAt: expiresAt))
    }

    @Test("Trial expiry transitions entitlement to .free and broadcasts update")
    func trialExpiryTransitionsToFree() async {
        let start = Date()
        let initialRecord = TrialRecord(
            activatedAt: start,
            duration: 15 * 86400,
            lastObservedDate: start,
            isExpired: false
        )
        let store = InMemoryTrialStore(record: initialRecord)
        let trialManager = TrialManager(store: store)
        let service = StoreKitSubscriptionService(trialManager: trialManager)

        // Set state to active trial initially
        let activeState = await service.refreshEntitlements()
        #expect(activeState.hasPremiumAccess == true)

        var stream = await service.stateUpdates().makeAsyncIterator()
        let currentInStream = await stream.next()
        #expect(currentInStream?.hasPremiumAccess == true)

        // Advance trial manager to day 16 (expired)
        let day16 = start.addingTimeInterval(16 * 86400)
        _ = await trialManager.status(at: day16)

        // Re-evaluate entitlement
        let expiredState = await service.refreshEntitlements()
        #expect(expiredState == .free)
        #expect(await service.isPremiumEntitled() == false)

        let nextInStream = await stream.next()
        #expect(nextInStream == .free)
    }
}
