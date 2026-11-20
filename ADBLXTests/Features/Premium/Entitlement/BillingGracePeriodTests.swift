import Foundation
import Testing
@testable import ADBLX

/// Billing Grace Period is on in App Store Connect: 16 days, paid-to-paid renewals only, sandbox
/// and production (docs/AppStoreSetup.md). When a renewal fails, StoreKit keeps the subscription
/// in `currentEntitlements` for the grace period, with its `expirationDate` already in the past and
/// the grace end in the renewal info. After that it is in billing retry and grants nothing.
@Suite("Billing grace period and billing retry")
struct BillingGracePeriodTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: TimeInterval = 86400

    private func subscription(
        _ productID: String, expired daysAgo: Double, graceEnds graceDays: Double?, inBillingRetry: Bool
    ) -> StoreEntitlement {
        StoreEntitlement(
            transactionID: 7, productID: productID,
            expirationDate: now.addingTimeInterval(-daysAgo * day), revocationDate: nil, verification: .verified,
            gracePeriodExpirationDate: graceDays.map { now.addingTimeInterval($0 * day) },
            inBillingRetry: inBillingRetry
        )
    }

    @Test("a subscription in its grace period is entitled, and readers outside the app honour it until grace ends",
          arguments: [StoreKitSubscriptionService.annualProductID, StoreKitSubscriptionService.monthlyProductID])
    func gracePeriodIsEntitled(productID: String) throws {
        let graceEnd = now.addingTimeInterval(14 * day)
        let resolved = StoreKitSubscriptionService.resolve(
            entitlements: [subscription(productID, expired: 2, graceEnds: 14, inBillingRetry: false)],
            trialCandidate: .free, at: now
        )

        #expect(resolved.state.hasPremiumAccess)
        #expect(resolved.paidProductID == productID)
        // The web extension and the tunnel stop at validUntil. Counted from the lapsed expiry, it
        // would cut a user in grace off after 7 of the 16 days.
        let validUntil = try #require(resolved.state.validUntil)
        #expect(validUntil >= graceEnd)
    }

    @Test("a subscription in billing retry after its grace period ended is not entitled")
    func billingRetryAfterGraceIsNotEntitled() {
        let resolved = StoreKitSubscriptionService.resolve(
            entitlements: [subscription(StoreKitSubscriptionService.annualProductID,
                                        expired: 20, graceEnds: -4, inBillingRetry: true)],
            trialCandidate: .free, at: now
        )

        #expect(resolved.state == .free)
        #expect(resolved.paidProductID == nil)
    }

    @Test("a subscription in billing retry with no grace period (not paid-to-paid) is not entitled")
    func billingRetryWithoutGraceIsNotEntitled() {
        let resolved = StoreKitSubscriptionService.resolve(
            entitlements: [subscription(StoreKitSubscriptionService.annualProductID,
                                        expired: 1, graceEnds: nil, inBillingRetry: true)],
            trialCandidate: .free, at: now
        )

        #expect(resolved.state == .free)
    }

    @Test("an active subscription with no billing issue keeps its own expiry")
    func activeSubscriptionUnchanged() {
        let active = StoreEntitlement(
            transactionID: 8, productID: StoreKitSubscriptionService.annualProductID,
            expirationDate: now.addingTimeInterval(30 * day), revocationDate: nil, verification: .verified
        )
        let resolved = StoreKitSubscriptionService.resolve(entitlements: [active], trialCandidate: .free, at: now)

        #expect(resolved.state == .annual(expiresAt: now.addingTimeInterval(30 * day)))
    }
}
