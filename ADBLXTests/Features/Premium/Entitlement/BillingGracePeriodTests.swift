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
        // would cut a user in grace off after 7 of the 16 days; with the usual 7 days of slack
        // added to the grace end, a 16-day grace would last 23 days there. It is the grace end.
        let validUntil = try #require(resolved.state.validUntil)
        #expect(validUntil == graceEnd)
    }

    @Test("unverified renewal info grants no grace: access stays what StoreKit's transaction gives")
    func unverifiedRenewalInfoGrantsNoGrace() throws {
        let expiry = now.addingTimeInterval(-2 * day)
        let listed = StoreEntitlement(
            transactionID: 9, productID: StoreKitSubscriptionService.annualProductID,
            expirationDate: expiry, revocationDate: nil, verification: .verified
        )
        let mapped = listed.withRenewal(
            inBillingRetry: false, gracePeriodExpirationDate: now.addingTimeInterval(14 * day), renewalVerified: false
        )
        #expect(mapped.gracePeriodExpirationDate == nil)

        let resolved = StoreKitSubscriptionService.resolve(entitlements: [mapped], trialCandidate: .free, at: now)
        #expect(resolved.state == .annual(expiresAt: expiry))
        let validUntil = try #require(resolved.state.validUntil)
        #expect(validUntil == expiry.addingTimeInterval(EntitlementState.subscriptionExtensionSlack))
    }

    @Test("an active subscription with unverified renewal info is unaffected")
    func activeSubscriptionWithUnverifiedRenewalInfo() {
        let expiry = now.addingTimeInterval(30 * day)
        let active = StoreEntitlement(
            transactionID: 10, productID: StoreKitSubscriptionService.monthlyProductID,
            expirationDate: expiry, revocationDate: nil, verification: .verified
        )
        let mapped = active.withRenewal(inBillingRetry: false, gracePeriodExpirationDate: nil, renewalVerified: false)

        let resolved = StoreKitSubscriptionService.resolve(entitlements: [mapped], trialCandidate: .free, at: now)
        #expect(resolved.state == .monthly(expiresAt: expiry))
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
