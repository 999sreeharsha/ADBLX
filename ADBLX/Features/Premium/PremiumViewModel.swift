// ADBLX/Features/Premium/PremiumViewModel.swift
import Observation

@Observable
final class PremiumViewModel {
    enum RestoreOutcome: Equatable {
        case restored
        case nothingToRestore
    }

    private let service: SubscriptionService

    /// The locked feature that opened this paywall, if any.
    let focus: PremiumFeature?
    var status: SubscriptionStatus?
    var isLoading = false
    var purchaseError: Error?
    var restoreOutcome: RestoreOutcome?

    init(service: SubscriptionService, focus: PremiumFeature? = nil) {
        self.service = service
        self.focus = focus
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
        restoreOutcome = nil
        do {
            try await service.restorePurchases()
            status = await service.fetchStatus()
            restoreOutcome = status?.isPremium == true ? .restored : .nothingToRestore
        } catch {
            purchaseError = error
        }
        isLoading = false
    }
}
