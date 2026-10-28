// ADBLX/Features/Premium/StoreKitSubscriptionService.swift
import Foundation
import StoreKit
import UIKit
import os

/// StoreKit 2-backed implementation of both `SubscriptionService` (UI-facing) and
/// `EntitlementService` (background-safe) — single source of truth for entitlement state.
public actor StoreKitSubscriptionService: SubscriptionService, EntitlementService {
    public static let monthlyProductID = "com.ADBLX.ADBLX.premium.monthly"
    public static let annualProductID = "com.ADBLX.ADBLX.premium.annual"
    public static let lifetimeProductID = "com.ADBLX.ADBLX.premium.lifetime"

    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "StoreKitSubscriptionService")
    private static let signposter = OSSignposter(subsystem: "com.ADBLX.ADBLX", category: "StoreKitSubscriptionService")

    private let trialManager: TrialManagerProtocol
    private var state: EntitlementState = .free
    private var continuations: [UUID: AsyncStream<EntitlementState>.Continuation] = [:]
    private var transactionUpdatesTask: Task<Void, Never>?
    private var foregroundObserver: (any NSObjectProtocol)?

    public init(trialManager: TrialManagerProtocol = TrialManager()) {
        self.trialManager = trialManager
        startTransactionListener()
        setupForegroundObserver()
    }

    deinit {
        transactionUpdatesTask?.cancel()
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupForegroundObserver() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.refreshEntitlements()
            }
        }
    }

    public var currentState: EntitlementState {
        state
    }

    public func stateUpdates() -> AsyncStream<EntitlementState> {
        let (stream, continuation) = AsyncStream.makeStream(of: EntitlementState.self)
        let id = UUID()
        continuation.yield(state)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeContinuation(for: id)
            }
        }
        return stream
    }

    private func removeContinuation(for id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func startTransactionListener() {
        transactionUpdatesTask = Task.detached(priority: .background) { [weak self] in
            await self?.refreshEntitlements()

            for await update in Transaction.updates {
                guard let self else { break }
                let spID = Self.signposter.makeSignpostID()
                let updateInterval = Self.signposter.beginInterval("entitlement.transactionUpdate", id: spID)
                if case .verified(let transaction) = update {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
                Self.signposter.endInterval("entitlement.transactionUpdate", updateInterval)
            }
        }
    }

    @discardableResult
    public func refreshEntitlements() async -> EntitlementState {
        let spID = Self.signposter.makeSignpostID()
        let refreshInterval = Self.signposter.beginInterval("entitlement.refresh", id: spID)
        defer { Self.signposter.endInterval("entitlement.refresh", refreshInterval) }

        var highestState: EntitlementState = .free

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            let candidateState = mapTransactionToEntitlement(transaction)
            if candidateState.precedence > highestState.precedence {
                highestState = candidateState
            }
        }

        let trialCandidate = await trialManager.currentEntitlement(at: Date())
        if trialCandidate.precedence > highestState.precedence {
            highestState = trialCandidate
        }

        if highestState != self.state {
            let transitionID = Self.signposter.makeSignpostID()
            Self.signposter.emitEvent(
                "entitlement.stateChange",
                id: transitionID,
                "State changed to \(String(describing: highestState))"
            )
            Self.logger.info(
                "EntitlementState changed from \(String(describing: self.state)) to \(String(describing: highestState))"
            )
            self.state = highestState
            for continuation in continuations.values {
                continuation.yield(highestState)
            }
        }

        return highestState
    }

    private func mapTransactionToEntitlement(_ transaction: Transaction) -> EntitlementState {
        if transaction.productID == Self.lifetimeProductID {
            return .lifetime
        } else if transaction.productID == Self.annualProductID {
            let expDate = transaction.expirationDate ?? Date().addingTimeInterval(365 * 86400)
            return .annual(expiresAt: expDate)
        } else if transaction.productID == Self.monthlyProductID {
            let expDate = transaction.expirationDate ?? Date().addingTimeInterval(30 * 86400)
            return .monthly(expiresAt: expDate)
        }
        return .free
    }

    public func fetchStatus() async -> SubscriptionStatus {
        let isEntitled = currentState.hasPremiumAccess
        let products = (try? await Product.products(for: [
            Self.monthlyProductID,
            Self.annualProductID,
            Self.lifetimeProductID
        ])) ?? []

        let monthly = products.first(where: { $0.id == Self.monthlyProductID })
        let annual = products.first(where: { $0.id == Self.annualProductID })
        let lifetime = products.first(where: { $0.id == Self.lifetimeProductID })

        var plans: [SubscriptionPlan] = []
        if let monthly {
            plans.append(SubscriptionPlan(
                id: "monthly",
                name: monthly.displayName,
                priceDescription: monthly.displayPrice,
                billingPeriodDescription: "per month",
                isCurrentPlan: isEntitled
            ))
        }
        if let annual {
            plans.append(SubscriptionPlan(
                id: "annual",
                name: annual.displayName,
                priceDescription: annual.displayPrice,
                billingPeriodDescription: "per year",
                isCurrentPlan: isEntitled
            ))
        }
        if let lifetime {
            plans.append(SubscriptionPlan(
                id: "lifetime",
                name: lifetime.displayName,
                priceDescription: lifetime.displayPrice,
                billingPeriodDescription: "one-time",
                isCurrentPlan: isEntitled
            ))
        }

        return SubscriptionStatus(isPremium: isEntitled, plans: plans)
    }

    public func purchase(_ planID: String) async throws -> Bool {
        let productID: String
        switch planID {
        case "monthly": productID = Self.monthlyProductID
        case "annual": productID = Self.annualProductID
        case "lifetime": productID = Self.lifetimeProductID
        default: return false
        }

        guard let product = try await Product.products(for: [productID]).first else {
            return false
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                await transaction.finish()
                await refreshEntitlements()
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

    public func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    /// Cheap, cached read of the last resolved entitlement state.
    ///
    /// Callers on a hot or repeated path should use this. Callers that must not observe a
    /// stale value — notably anything publishing entitlement to another process before the
    /// async transaction listener has necessarily completed its first refresh — should use
    /// `resolvedPremiumEntitlement()` instead.
    public func isPremiumEntitled() async -> Bool {
        currentState.hasPremiumAccess
    }

    /// Forces a fresh StoreKit + trial resolution, then reports premium access.
    ///
    /// Exists because `state` is populated lazily by `startTransactionListener()`. At launch
    /// the Layer 3 bootstrap publishes `entitlement.json` from this value before that
    /// listener has necessarily finished, and reading the stale `.free` snapshot there left
    /// trial users with Layer 3 disabled until a second launch.
    public func resolvedPremiumEntitlement() async -> Bool {
        await refreshEntitlements().hasPremiumAccess
    }
}
