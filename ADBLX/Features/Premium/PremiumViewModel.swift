// ADBLX/Features/Premium/PremiumViewModel.swift
import Observation

@Observable
final class PremiumViewModel {
    private let service: SubscriptionService

    var status: SubscriptionStatus?
    var isLoading = false
    var purchaseError: Error?

    init(service: SubscriptionService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        status = await service.fetchStatus()
        isLoading = false
    }

    func purchase(planID: String) async {
        purchaseError = nil
        do {
            _ = try await service.purchase(planID)
            status = await service.fetchStatus()
        } catch {
            purchaseError = error
        }
    }

    func restore() async {
        isLoading = true
        purchaseError = nil
        do {
            try await service.restorePurchases()
            status = await service.fetchStatus()
        } catch {
            purchaseError = error
        }
        isLoading = false
    }
}
