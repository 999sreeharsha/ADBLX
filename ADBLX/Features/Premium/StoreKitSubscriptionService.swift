// ADBLX/Features/Premium/StoreKitSubscriptionService.swift
import StoreKit

/// StoreKit 2-backed implementation of both `SubscriptionService` (UI-facing) and
/// `EntitlementService` (background-safe) — one source of truth for entitlement state
/// consulted from Premium UI and from `UpdateCoordinator`'s pre-planning entitlement
/// check alike (Sprint 8.0 Commit 8).
final class StoreKitSubscriptionService: SubscriptionService, EntitlementService, Sendable {
    static let annualProductID = "com.ADBLX.ADBLX.premium.annual"
    static let lifetimeProductID = "com.ADBLX.ADBLX.premium.lifetime"

    init() {
        listenForTransactionUpdates()
    }

    private func listenForTransactionUpdates() {
        Task.detached(priority: .background) {
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
            }
        }
    }

    func fetchStatus() async -> SubscriptionStatus {
        let entitled = await isPremiumEntitled()
        let products = (try? await Product.products(for: [Self.annualProductID, Self.lifetimeProductID])) ?? []

        let annual = products.first(where: { $0.id == Self.annualProductID })
        let lifetime = products.first(where: { $0.id == Self.lifetimeProductID })

        var plans: [SubscriptionPlan] = []
        if let annual {
            plans.append(SubscriptionPlan(
                id: "annual", name: annual.displayName,
                priceDescription: annual.displayPrice, billingPeriodDescription: "per year",
                isCurrentPlan: entitled
            ))
        }
        if let lifetime {
            plans.append(SubscriptionPlan(
                id: "lifetime", name: lifetime.displayName,
                priceDescription: lifetime.displayPrice, billingPeriodDescription: "one-time",
                isCurrentPlan: entitled
            ))
        }

        return SubscriptionStatus(isPremium: entitled, plans: plans)
    }

    func purchase(_ planID: String) async throws -> Bool {
        let productID = planID == "annual" ? Self.annualProductID : Self.lifetimeProductID
        guard let product = try await Product.products(for: [productID]).first else {
            return false
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                return true
            case .unverified:
                return false
            }
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
    }

    func isPremiumEntitled() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.annualProductID || transaction.productID == Self.lifetimeProductID {
                return true
            }
        }
        return false
    }
}
