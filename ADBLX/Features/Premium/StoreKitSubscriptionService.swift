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
    private let entitlementSource: StoreEntitlementSource
    private let acceptsXcodeUnverified: Bool
    private var state: EntitlementState = .free
    private var resolvedSnapshot = EntitlementSnapshot()
    private var refreshChain: Task<EntitlementState, Never>?
    private var continuations: [UUID: AsyncStream<EntitlementState>.Continuation] = [:]
    private var transactionUpdatesTask: Task<Void, Never>?
    private var foregroundObserver: (any NSObjectProtocol)?

    /// DEBUG builds running under Xcode's local StoreKit configuration may receive transactions
    /// StoreKit reports as unverified (the local test certificate chain is not always trusted
    /// on a device). Those are honoured ONLY when `Transaction.environment == .xcode`; a
    /// release build never honours an unverified transaction.
    static var defaultAcceptsXcodeUnverified: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public convenience init(trialManager: TrialManagerProtocol = TrialManager()) {
        self.init(
            trialManager: trialManager,
            entitlementSource: StoreKitEntitlementSource(),
            acceptsXcodeUnverified: Self.defaultAcceptsXcodeUnverified
        )
    }

    init(
        trialManager: TrialManagerProtocol,
        entitlementSource: StoreEntitlementSource,
        acceptsXcodeUnverified: Bool
    ) {
        self.trialManager = trialManager
        self.entitlementSource = entitlementSource
        self.acceptsXcodeUnverified = acceptsXcodeUnverified
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
        let source = entitlementSource
        transactionUpdatesTask = Task.detached(priority: .background) { [weak self] in
            await self?.refreshEntitlements()

            for await update in source.updates() {
                guard let self else { break }
                let spID = Self.signposter.makeSignpostID()
                let updateInterval = Self.signposter.beginInterval("entitlement.transactionUpdate", id: spID)
                if await self.isAcceptable(update) {
                    await source.finish(update)
                }
                await self.refreshEntitlements()
                Self.signposter.endInterval("entitlement.transactionUpdate", updateInterval)
            }
        }
    }

    private func isAcceptable(_ entitlement: StoreEntitlement) -> Bool {
        switch entitlement.verification {
        case .verified: return true
        case .unverified: return acceptsXcodeUnverified && entitlement.isXcodeEnvironment
        }
    }

    /// Refreshes run strictly one after another. `refreshEntitlements` awaits StoreKit while
    /// iterating, and actors are re-entrant, so without this a refresh that began before a
    /// purchase could finish after it and overwrite the newer entitled state with `.free`.
    @discardableResult
    public func refreshEntitlements() async -> EntitlementState {
        let previous = refreshChain
        let task = Task { () -> EntitlementState in
            _ = await previous?.value
            return await self.performRefresh()
        }
        refreshChain = task
        return await task.value
    }

    private func performRefresh() async -> EntitlementState {
        let spID = Self.signposter.makeSignpostID()
        let refreshInterval = Self.signposter.beginInterval("entitlement.refresh", id: spID)
        defer { Self.signposter.endInterval("entitlement.refresh", refreshInterval) }

        let entitlements = await entitlementSource.currentEntitlements()
        let trialCandidate = await trialManager.currentEntitlement(at: Date())
        let resolved = Self.resolve(
            entitlements: entitlements, trialCandidate: trialCandidate, acceptsXcodeUnverified: acceptsXcodeUnverified
        )

        // The snapshot is committed before the state is published, so a consumer woken by
        // `stateUpdates()` always reads the entitlement that caused the wake-up.
        resolvedSnapshot = resolved
        let highestState = resolved.state

        if resolved.unverifiedErrors.isEmpty == false {
            Self.logger.notice(
                "unverified entitlements=\(resolved.unverifiedErrors.count) accepted=\(resolved.acceptedUnverifiedCount)"
            )
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

    /// Pure resolution rules. Paid always outranks the trial by `precedence`; an expired trial
    /// and the "continue free" choice contribute nothing here (they are `.free`).
    static func resolve(
        entitlements: [StoreEntitlement],
        trialCandidate: EntitlementState,
        acceptsXcodeUnverified: Bool
    ) -> EntitlementSnapshot {
        var snapshot = EntitlementSnapshot(hasResolved: true)
        var best: EntitlementState = .free
        var bestProductID: String?

        for entitlement in entitlements where entitlement.revocationDate == nil {
            switch entitlement.verification {
            case .verified:
                snapshot.verifiedCount += 1
            case .unverified(let name):
                snapshot.unverifiedErrors.append(name)
                guard acceptsXcodeUnverified && entitlement.isXcodeEnvironment else { continue }
                snapshot.acceptedUnverifiedCount += 1
            }
            let candidate = state(for: entitlement)
            if candidate.precedence > best.precedence {
                best = candidate
                bestProductID = entitlement.productID
            }
        }

        if best.precedence >= 2 {
            snapshot.paidProductID = bestProductID
            snapshot.paidKind = bestProductID.flatMap { premiumKind(forProductID: $0) }
        }
        if trialCandidate.precedence > best.precedence {
            best = trialCandidate
        }
        snapshot.state = best
        return snapshot
    }

    private static func state(for entitlement: StoreEntitlement) -> EntitlementState {
        switch entitlement.productID {
        case lifetimeProductID:
            return .lifetime
        case annualProductID:
            return .annual(expiresAt: entitlement.expirationDate ?? .distantFuture)
        case monthlyProductID:
            return .monthly(expiresAt: entitlement.expirationDate ?? .distantFuture)
        default:
            return .free
        }
    }

    /// What the last refresh resolved, including verification counts for diagnostics.
    func snapshot() -> EntitlementSnapshot { resolvedSnapshot }

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

        switch try await entitlementSource.purchase(productID: productID) {
        case .success(let entitlement):
            guard isAcceptable(entitlement) else {
                // Do NOT finish it: an unverified transaction must not be consumed, and the
                // user must be told rather than left looking at an unchanged paywall.
                if case .unverified(let name) = entitlement.verification {
                    Self.logger.error("purchase returned an unverified transaction: \(name, privacy: .public)")
                    throw SubscriptionPurchaseError.unverifiedTransaction(name)
                }
                return false
            }
            await entitlementSource.finish(entitlement)
            await refreshEntitlements()
            return true
        case .cancelled, .pending, .unknownProduct:
            return false
        }
    }

    public func restorePurchases() async throws {
        try await entitlementSource.sync()
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

    // MARK: - Plan state support

    nonisolated static func premiumKind(forProductID productID: String) -> PremiumKind? {
        switch productID {
        case monthlyProductID, annualProductID: return .subscription
        case lifetimeProductID: return .lifetime
        default: return nil
        }
    }

    /// The paid (non-trial) Premium from the SAME resolution that `currentState` came from —
    /// never a second StoreKit query, so the DNS gate, the plan state and the reconciler cannot
    /// disagree.
    func activePremiumKind() async -> PremiumKind? {
        if !resolvedSnapshot.hasResolved { await refreshEntitlements() }
        return resolvedSnapshot.paidKind
    }
}

extension StoreKitSubscriptionService: PaidEntitlementSource {}
