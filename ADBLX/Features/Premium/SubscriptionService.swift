// ADBLX/Features/Premium/SubscriptionService.swift
import Foundation

struct SubscriptionPlan: Equatable, Identifiable {
    var id: String
    let name: String
    let priceDescription: String
    let billingPeriodDescription: String
    let isCurrentPlan: Bool
}

struct SubscriptionStatus: Equatable {
    let isPremium: Bool
    let plans: [SubscriptionPlan]
}

/// What Premium needs from the store. A later sprint's real implementation
/// wraps StoreKit 2 behind this protocol — PremiumView/PremiumViewModel do
/// not change (Sprint 4 spec §5).
protocol SubscriptionService: Sendable {
    func fetchStatus() async -> SubscriptionStatus
    func purchase(_ planID: String) async throws -> Bool
    func restorePurchases() async throws
}

/// Narrow, background-safe entitlement check — distinct from `SubscriptionService`
/// so `UpdateCoordinator`/`UpdatePlanner` (no UI, may run off-main-actor at launch)
/// never need to depend on UI-shaped types like `SubscriptionStatus`/`SubscriptionPlan`.
protocol EntitlementService: Sendable {
    func isPremiumEntitled() async -> Bool
}

struct MockSubscriptionService: SubscriptionService, EntitlementService {
    func fetchStatus() async -> SubscriptionStatus {
        SubscriptionStatus(
            isPremium: false,
            plans: [
                SubscriptionPlan(
                    id: "annual", name: "Annual", priceDescription: "$19.99",
                    billingPeriodDescription: "per year", isCurrentPlan: false
                ),
                SubscriptionPlan(
                    id: "lifetime", name: "Lifetime", priceDescription: "$49.99",
                    billingPeriodDescription: "one-time", isCurrentPlan: false
                ),
            ]
        )
    }

    func purchase(_ planID: String) async throws -> Bool { true }

    func restorePurchases() async throws {}

    func isPremiumEntitled() async -> Bool { false }
}
