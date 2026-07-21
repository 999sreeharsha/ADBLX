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
}

struct MockSubscriptionService: SubscriptionService {
    func fetchStatus() async -> SubscriptionStatus {
        SubscriptionStatus(
            isPremium: false,
            plans: [
                SubscriptionPlan(id: "monthly", name: "Monthly", priceDescription: "$2.99", billingPeriodDescription: "per month", isCurrentPlan: false),
                SubscriptionPlan(id: "annual", name: "Annual", priceDescription: "$19.99", billingPeriodDescription: "per year", isCurrentPlan: false),
                SubscriptionPlan(id: "lifetime", name: "Lifetime", priceDescription: "$49.99", billingPeriodDescription: "one-time", isCurrentPlan: false),
            ]
        )
    }

    func purchase(_ planID: String) async throws -> Bool { true }
}
