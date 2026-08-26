// ADBLX/Features/Premium/SubscriptionService.swift
import Foundation

public struct SubscriptionPlan: Equatable, Identifiable, Sendable {
    public var id: String
    public let name: String
    public let priceDescription: String
    public let billingPeriodDescription: String
    public let isCurrentPlan: Bool

    public init(
        id: String,
        name: String,
        priceDescription: String,
        billingPeriodDescription: String,
        isCurrentPlan: Bool
    ) {
        self.id = id
        self.name = name
        self.priceDescription = priceDescription
        self.billingPeriodDescription = billingPeriodDescription
        self.isCurrentPlan = isCurrentPlan
    }
}

public struct SubscriptionStatus: Equatable, Sendable {
    public let isPremium: Bool
    public let plans: [SubscriptionPlan]

    public init(isPremium: Bool, plans: [SubscriptionPlan]) {
        self.isPremium = isPremium
        self.plans = plans
    }
}

public enum EntitlementState: Sendable, Equatable {
    case free
    case trial(expiresAt: Date)
    case monthly(expiresAt: Date)
    case annual(expiresAt: Date)
    case lifetime
}

public extension EntitlementState {
    var hasPremiumAccess: Bool {
        self != .free
    }

    var precedence: Int {
        switch self {
        case .lifetime: return 4
        case .annual: return 3
        case .monthly: return 2
        case .trial: return 1
        case .free: return 0
        }
    }
}

public protocol SubscriptionService: Sendable {
    func fetchStatus() async -> SubscriptionStatus
    func purchase(_ planID: String) async throws -> Bool
    func restorePurchases() async throws
}

public protocol EntitlementService: Sendable {
    var currentState: EntitlementState { get async }
    func stateUpdates() -> AsyncStream<EntitlementState>
    func isPremiumEntitled() async -> Bool
    @discardableResult
    func refreshEntitlements() async -> EntitlementState
}

public extension EntitlementService {
    func isPremiumEntitled() async -> Bool {
        await currentState.hasPremiumAccess
    }
}

public final class MockSubscriptionService: SubscriptionService, EntitlementService, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: EntitlementState
    private var continuations: [UUID: AsyncStream<EntitlementState>.Continuation] = [:]
    public var plans: [SubscriptionPlan]

    public init(
        state: EntitlementState = .free,
        plans: [SubscriptionPlan] = [
            SubscriptionPlan(
                id: "monthly",
                name: "Monthly",
                priceDescription: "$1.99",
                billingPeriodDescription: "per month",
                isCurrentPlan: false
            ),
            SubscriptionPlan(
                id: "annual",
                name: "Annual",
                priceDescription: "$14.99",
                billingPeriodDescription: "per year",
                isCurrentPlan: false
            ),
            SubscriptionPlan(
                id: "lifetime",
                name: "Lifetime",
                priceDescription: "$39.99",
                billingPeriodDescription: "one-time",
                isCurrentPlan: false
            )
        ]
    ) {
        self._state = state
        self.plans = plans
    }

    public var currentState: EntitlementState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public func updateState(_ newState: EntitlementState) {
        lock.lock()
        guard _state != newState else {
            lock.unlock()
            return
        }
        _state = newState
        let conns = Array(continuations.values)
        lock.unlock()
        for continuation in conns {
            continuation.yield(newState)
        }
    }

    public func stateUpdates() -> AsyncStream<EntitlementState> {
        let (stream, continuation) = AsyncStream.makeStream(of: EntitlementState.self)
        let id = UUID()
        lock.lock()
        continuation.yield(_state)
        continuations[id] = continuation
        lock.unlock()

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations.removeValue(forKey: id)
            self.lock.unlock()
        }
        return stream
    }

    public func isPremiumEntitled() async -> Bool {
        currentState.hasPremiumAccess
    }

    public func refreshEntitlements() async -> EntitlementState {
        currentState
    }

    public func fetchStatus() async -> SubscriptionStatus {
        let isPrem = currentState.hasPremiumAccess
        let updatedPlans = plans.map { plan in
            SubscriptionPlan(
                id: plan.id,
                name: plan.name,
                priceDescription: plan.priceDescription,
                billingPeriodDescription: plan.billingPeriodDescription,
                isCurrentPlan: isPrem
            )
        }
        return SubscriptionStatus(isPremium: isPrem, plans: updatedPlans)
    }

    public func purchase(_ planID: String) async throws -> Bool {
        if planID == "monthly" {
            updateState(.monthly(expiresAt: Date().addingTimeInterval(30 * 86400)))
        } else if planID == "annual" {
            updateState(.annual(expiresAt: Date().addingTimeInterval(365 * 86400)))
        } else if planID == "lifetime" {
            updateState(.lifetime)
        }
        return true
    }

    public func restorePurchases() async throws {}
}
