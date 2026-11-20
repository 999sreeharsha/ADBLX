import Foundation
import StoreKit

/// One StoreKit transaction, reduced to what entitlement resolution needs. Contains no
/// account or receipt data — product IDs, dates and enum names only.
nonisolated struct StoreEntitlement: Equatable, Sendable {
    enum Verification: Equatable, Sendable {
        case verified
        /// StoreKit could not verify the signature. Carries only the error's case name
        /// (e.g. "invalidCertificateChain").
        case unverified(String)
    }

    let transactionID: UInt64
    let productID: String
    let expirationDate: Date?
    let revocationDate: Date?
    let verification: Verification
    /// When a subscription whose renewal failed stops granting access, from its signed renewal
    /// info. Set only during a billing grace period; the transaction's own `expirationDate` has
    /// already passed by then.
    var gracePeriodExpirationDate: Date?
    /// StoreKit reports the subscription in billing retry: renewal failed and Apple is still
    /// trying to charge. Access continues only while a grace period lasts.
    var inBillingRetry = false
}

nonisolated enum StorePurchaseOutcome: Sendable {
    case success(StoreEntitlement)
    case cancelled
    case pending
    case unknownProduct
}

/// The seam between entitlement resolution and StoreKit, so the resolution rules (paid beats
/// trial, ordering, unverified handling, finishing) are unit-testable without a StoreKit
/// session — which does not activate under headless `xcodebuild test` (see docs/gotchas.md).
nonisolated protocol StoreEntitlementSource: Sendable {
    func currentEntitlements() async -> [StoreEntitlement]
    /// Transactions that arrive outside `purchase` (renewals, refunds, Ask to Buy, other devices).
    func updates() -> AsyncStream<StoreEntitlement>
    func purchase(productID: String) async throws -> StorePurchaseOutcome
    /// Marks a transaction finished. Only called for transactions the service accepted.
    func finish(_ entitlement: StoreEntitlement) async
    func sync() async throws
}

/// Live StoreKit 2 implementation.
nonisolated final class StoreKitEntitlementSource: StoreEntitlementSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt64: Transaction] = [:]

    func currentEntitlements() async -> [StoreEntitlement] {
        var result: [StoreEntitlement] = []
        for await verification in Transaction.currentEntitlements {
            result.append(await Self.entitlement(from: verification))
        }
        return result
    }

    func updates() -> AsyncStream<StoreEntitlement> {
        AsyncStream { continuation in
            let task = Task.detached { [self] in
                for await verification in Transaction.updates {
                    remember(verification)
                    continuation.yield(await Self.entitlement(from: verification))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func purchase(productID: String) async throws -> StorePurchaseOutcome {
        guard let product = try await Product.products(for: [productID]).first else { return .unknownProduct }
        switch try await product.purchase() {
        case .success(let verification):
            remember(verification)
            return .success(await Self.entitlement(from: verification))
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .cancelled
        }
    }

    func finish(_ entitlement: StoreEntitlement) async {
        lock.lock()
        let transaction = pending.removeValue(forKey: entitlement.transactionID)
        lock.unlock()
        await transaction?.finish()
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    private func remember(_ verification: VerificationResult<Transaction>) {
        let transaction = verification.unsafePayloadValue
        lock.lock()
        pending[transaction.id] = transaction
        lock.unlock()
    }

    /// Adds a subscription's renewal state: billing retry, and the grace period's end from its
    /// renewal info, read only when that info verifies.
    private static func entitlement(from verification: VerificationResult<Transaction>) async -> StoreEntitlement {
        var entitlement = map(verification)
        let transaction = verification.unsafePayloadValue
        guard transaction.productType == .autoRenewable, let status = await transaction.subscriptionStatus else {
            return entitlement
        }
        entitlement.inBillingRetry = status.state == .inBillingRetryPeriod
        if case .verified(let renewalInfo) = status.renewalInfo {
            entitlement.gracePeriodExpirationDate = renewalInfo.gracePeriodExpirationDate
        }
        return entitlement
    }

    private static func map(_ verification: VerificationResult<Transaction>) -> StoreEntitlement {
        let transaction = verification.unsafePayloadValue
        let status: StoreEntitlement.Verification
        switch verification {
        case .verified:
            status = .verified
        case .unverified(_, let error):
            status = .unverified(caseName(of: error))
        }
        return StoreEntitlement(
            transactionID: transaction.id,
            productID: transaction.productID,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            verification: status
        )
    }

    /// Bare enum case name — never the payload or localized text.
    private static func caseName(of error: Error) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }
}
