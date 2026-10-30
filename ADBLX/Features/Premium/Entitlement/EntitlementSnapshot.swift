import Foundation

/// The output of one entitlement resolution. Counts, enum case names and product IDs only
/// (docs/Architecture/Logging.md) — safe to log and to show in the developer section.
nonisolated struct EntitlementSnapshot: Equatable, Sendable {
    var state: EntitlementState = .free
    var paidKind: PremiumKind?
    var paidProductID: String?
    var verifiedCount = 0
    /// StoreKit verification error case names for unverified entitlements, e.g. "invalidSignature".
    var unverifiedErrors: [String] = []
    /// Unverified entitlements honoured under the DEBUG + Xcode-environment allowance.
    var acceptedUnverifiedCount = 0
    var hasResolved = false
}

/// Thrown by `purchase` so the paywall can show the user why nothing changed.
nonisolated enum SubscriptionPurchaseError: LocalizedError, Equatable {
    case unverifiedTransaction(String)

    var errorDescription: String? {
        String(localized: "Your purchase could not be verified, so it was not applied. Try Restore Purchases, or contact support.")
    }
}
