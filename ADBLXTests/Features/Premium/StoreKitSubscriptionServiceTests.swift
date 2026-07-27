// ADBLXTests/Features/Premium/StoreKitSubscriptionServiceTests.swift
import Testing
import StoreKit
@testable import ADBLX

@Suite("StoreKitSubscriptionService")
struct StoreKitSubscriptionServiceTests {
    @Test("isPremiumEntitled is false with no transactions")
    func isPremiumEntitledFalseWithNoTransactions() async throws {
        let service = StoreKitSubscriptionService()
        let entitled = await service.isPremiumEntitled()
        #expect(entitled == false)
    }

    @Test("fetchStatus returns exactly two plans: annual and lifetime")
    func fetchStatusReturnsTwoPlans() async throws {
        let service = StoreKitSubscriptionService()
        let status = await service.fetchStatus()
        #expect(status.plans.map(\.id).sorted() == ["annual", "lifetime"])
    }
}
