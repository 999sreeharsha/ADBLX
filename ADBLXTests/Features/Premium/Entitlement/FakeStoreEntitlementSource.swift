import Foundation
@testable import ADBLX

/// Scriptable stand-in for StoreKit. `currentEntitlements()` replays `script` in call order
/// (each step has its own latency), then repeats `entitlements`.
nonisolated final class FakeStoreEntitlementSource: @unchecked Sendable {
    struct Step { var entitlements: [StoreEntitlement]; var delayNanoseconds: UInt64 = 0 }

    private let lock = NSLock()
    private var script: [Step] = []
    private var _entitlements: [StoreEntitlement]
    private var _readCount = 0
    private var _finished: [UInt64] = []
    private var continuation: AsyncStream<StoreEntitlement>.Continuation?
    private var waiters: [(condition: @Sendable (Observed) -> Bool, resume: CheckedContinuation<Void, Never>)] = []
    var purchaseOutcome: StorePurchaseOutcome = .cancelled

    init(_ entitlements: [StoreEntitlement] = []) { _entitlements = entitlements }

    func setEntitlements(_ new: [StoreEntitlement]) { lock.lock(); _entitlements = new; lock.unlock() }
    func setScript(_ steps: [Step]) { lock.lock(); script = steps; lock.unlock() }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return _readCount }
    var finished: [UInt64] { lock.lock(); defer { lock.unlock() }; return _finished }

    func emitUpdate(_ entitlement: StoreEntitlement) { lock.lock(); let c = continuation; lock.unlock(); c?.yield(entitlement) }

    /// What a test can wait on.
    struct Observed: Sendable {
        let readCount: Int
        let finished: [UInt64]
        /// `updates()` has been called, so `emitUpdate` reaches a listener instead of nothing.
        let isListening: Bool
    }

    /// Suspends until `condition` holds, checked now and after every change to this source, so a
    /// test never guesses how long the service takes. Bound it with a `.timeLimit` trait.
    func wait(until condition: @escaping @Sendable (Observed) -> Bool) async {
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            lock.lock()
            if condition(observedLocked()) {
                lock.unlock()
                resume.resume()
            } else {
                waiters.append((condition, resume))
                lock.unlock()
            }
        }
    }

    private func observedLocked() -> Observed {
        Observed(readCount: _readCount, finished: _finished, isListening: continuation != nil)
    }

    /// Call with the lock held after a change; resume what it returns once the lock is released.
    private func readyWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        let observed = observedLocked()
        var ready: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            guard waiter.condition(observed) else { return false }
            ready.append(waiter.resume)
            return true
        }
        return ready
    }

    func currentEntitlements() async -> [StoreEntitlement] {
        lock.lock()
        _readCount += 1
        let step: Step? = script.isEmpty ? nil : script.removeFirst()
        let fallback = _entitlements
        let ready = readyWaitersLocked()
        lock.unlock()
        ready.forEach { $0.resume() }
        if let step {
            if step.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: step.delayNanoseconds) }
            return step.entitlements
        }
        return fallback
    }

    func updates() -> AsyncStream<StoreEntitlement> {
        let (stream, cont) = AsyncStream.makeStream(of: StoreEntitlement.self)
        lock.lock()
        continuation = cont
        let ready = readyWaitersLocked()
        lock.unlock()
        ready.forEach { $0.resume() }
        return stream
    }

    func purchase(productID: String) async throws -> StorePurchaseOutcome {
        lock.lock(); let outcome = purchaseOutcome; lock.unlock()
        if case .success(let entitlement) = outcome {
            lock.lock(); _entitlements.append(entitlement); lock.unlock()   // StoreKit now reports it
        }
        return outcome
    }

    func finish(_ entitlement: StoreEntitlement) async {
        lock.lock()
        _finished.append(entitlement.transactionID)
        let ready = readyWaitersLocked()
        lock.unlock()
        ready.forEach { $0.resume() }
    }
    func sync() async throws {}
}

extension FakeStoreEntitlementSource: StoreEntitlementSource {}

extension StoreEntitlement {
    static func annual(id: UInt64 = 1, expires: Date = Date().addingTimeInterval(86400 * 365)) -> StoreEntitlement {
        StoreEntitlement(transactionID: id, productID: StoreKitSubscriptionService.annualProductID,
                         expirationDate: expires, revocationDate: nil, verification: .verified)
    }
    static func lifetime(id: UInt64 = 2) -> StoreEntitlement {
        StoreEntitlement(transactionID: id, productID: StoreKitSubscriptionService.lifetimeProductID,
                         expirationDate: nil, revocationDate: nil, verification: .verified)
    }
    func with(verification: Verification? = nil, revoked: Date? = nil) -> StoreEntitlement {
        StoreEntitlement(transactionID: transactionID, productID: productID, expirationDate: expirationDate,
                         revocationDate: revoked ?? revocationDate, verification: verification ?? self.verification)
    }
}
