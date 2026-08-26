// ADBLXTests/Features/Premium/StoreKitSubscriptionServiceTests.swift
import Testing
import StoreKit
import Foundation
@testable import ADBLX

@Suite("StoreKitSubscriptionService")
struct StoreKitSubscriptionServiceTests {
    @Test("currentState is .free with no transactions")
    func initialStateIsFreeWithNoTransactions() async throws {
        let service = StoreKitSubscriptionService()
        let state = await service.currentState
        #expect(state == .free)
        let entitled = await service.isPremiumEntitled()
        #expect(entitled == false)
    }

    @Test("stateUpdates() yields current state immediately to new subscribers")
    func stateUpdatesYieldsCurrentStateImmediately() async throws {
        let service = StoreKitSubscriptionService()
        var iterator = await service.stateUpdates().makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial == .free)
    }

    @Test("Multiple subscribers receive initial state independently")
    func multipleSubscribersReceiveInitialState() async throws {
        let service = StoreKitSubscriptionService()
        var iter1 = await service.stateUpdates().makeAsyncIterator()
        var iter2 = await service.stateUpdates().makeAsyncIterator()
        
        let initial1 = await iter1.next()
        let initial2 = await iter2.next()
        #expect(initial1 == .free)
        #expect(initial2 == .free)
    }

    @Test(
        "fetchStatus returns three plans: monthly, annual, lifetime",
        .disabled("Skipped: StoreKit Local Configuration does not activate correctly under headless xcodebuild test on the current Xcode toolchain. Verified manually in Xcode GUI.")
    )
    func fetchStatusReturnsThreePlans() async throws {
        let service = StoreKitSubscriptionService()
        let status = await service.fetchStatus()
        #expect(status.plans.map(\.id).sorted() == ["annual", "lifetime", "monthly"])
    }
}
