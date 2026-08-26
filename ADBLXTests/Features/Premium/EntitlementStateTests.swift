// ADBLXTests/Features/Premium/EntitlementStateTests.swift
import Foundation
import Testing
@testable import ADBLX

@Suite("EntitlementState")
struct EntitlementStateTests {
    @Test("hasPremiumAccess invariant")
    func hasPremiumAccessInvariant() {
        let now = Date()
        #expect(EntitlementState.free.hasPremiumAccess == false)
        #expect(EntitlementState.trial(expiresAt: now.addingTimeInterval(86400)).hasPremiumAccess == true)
        #expect(EntitlementState.monthly(expiresAt: now.addingTimeInterval(86400)).hasPremiumAccess == true)
        #expect(EntitlementState.annual(expiresAt: now.addingTimeInterval(86400)).hasPremiumAccess == true)
        #expect(EntitlementState.lifetime.hasPremiumAccess == true)
    }

    @Test("Precedence invariant: lifetime > annual > monthly > trial > free")
    func precedenceInvariant() {
        let now = Date()
        let free = EntitlementState.free
        let trial = EntitlementState.trial(expiresAt: now.addingTimeInterval(15 * 86400))
        let monthly = EntitlementState.monthly(expiresAt: now.addingTimeInterval(30 * 86400))
        let annual = EntitlementState.annual(expiresAt: now.addingTimeInterval(365 * 86400))
        let lifetime = EntitlementState.lifetime

        #expect(lifetime.precedence > annual.precedence)
        #expect(annual.precedence > monthly.precedence)
        #expect(monthly.precedence > trial.precedence)
        #expect(trial.precedence > free.precedence)
    }

    @Test("MockSubscriptionService immediately yields initial state on stateUpdates()")
    func mockSubscriptionServiceImmediateInitialState() async {
        let service = MockSubscriptionService(state: .free)
        var stream = service.stateUpdates().makeAsyncIterator()
        
        let initial = await stream.next()
        #expect(initial == .free)
    }

    @Test("MockSubscriptionService broadcasts state updates to multiple independent subscribers")
    func mockSubscriptionServiceMultipleSubscribers() async {
        let service = MockSubscriptionService(state: .free)
        var stream1 = service.stateUpdates().makeAsyncIterator()
        var stream2 = service.stateUpdates().makeAsyncIterator()

        let initial1 = await stream1.next()
        let initial2 = await stream2.next()
        #expect(initial1 == .free)
        #expect(initial2 == .free)

        let targetDate = Date().addingTimeInterval(365 * 86400)
        let targetState = EntitlementState.annual(expiresAt: targetDate)
        service.updateState(targetState)

        let next1 = await stream1.next()
        let next2 = await stream2.next()
        #expect(next1 == targetState)
        #expect(next2 == targetState)
    }
}
