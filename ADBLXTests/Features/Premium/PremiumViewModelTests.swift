// ADBLXTests/Features/Premium/PremiumViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("PremiumViewModel")
struct PremiumViewModelTests {
    @Test("load() populates status from the injected service")
    func loadPopulatesStatus() async {
        let expected = SubscriptionStatus(
            isPremium: false,
            plans: [
                SubscriptionPlan(id: "monthly", name: "Monthly", priceDescription: "$2.99", billingPeriodDescription: "per month", isCurrentPlan: false),
            ]
        )
        let viewModel = PremiumViewModel(service: StubSubscriptionService(statusToReturn: expected))

        await viewModel.load()

        #expect(viewModel.status == expected)
    }

    @Test("purchase(planID:) sets purchaseError when the service throws")
    func purchaseSurfacesError() async {
        let viewModel = PremiumViewModel(service: FailingSubscriptionService())

        await viewModel.purchase(planID: "monthly")

        #expect(viewModel.purchaseError != nil)
    }

    @Test("purchase(planID:) clears purchaseError and reloads status on success")
    func purchaseSucceeds() async {
        let status = SubscriptionStatus(isPremium: false, plans: [])
        let service = StubSubscriptionService(statusToReturn: status)
        let viewModel = PremiumViewModel(service: service)

        await viewModel.purchase(planID: "monthly")

        #expect(viewModel.purchaseError == nil)
    }
}

private struct StubSubscriptionService: SubscriptionService {
    let statusToReturn: SubscriptionStatus
    func fetchStatus() async -> SubscriptionStatus { statusToReturn }
    func purchase(_ planID: String) async throws -> Bool { true }
}

private struct FailingSubscriptionService: SubscriptionService {
    struct PurchaseError: Error {}
    func fetchStatus() async -> SubscriptionStatus { SubscriptionStatus(isPremium: false, plans: []) }
    func purchase(_ planID: String) async throws -> Bool { throw PurchaseError() }
}
