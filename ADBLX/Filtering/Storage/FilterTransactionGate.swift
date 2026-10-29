import Foundation

/// Serializes every operation that takes a `FilterStore` rollback snapshot and mutates
/// `Compiled/` / `Metadata/` / `Filters/` (an `UpdateCoordinator` transaction, an entitlement
/// downgrade). Actor isolation alone does not do this: each of those spans many awaits, and
/// both share the single `Previous/` snapshot directory, so overlapping them would let one
/// restore or discard the other's snapshot.
///
/// Busy behavior (deliberate): a caller that finds the gate held **waits its turn** and then
/// runs; it is never dropped and never silently skipped. Waiters resume strictly FIFO. So a
/// reconcile that arrives mid-update runs right after the update commits (and sees its
/// result), and an update that arrives mid-reconcile waits for the downgrade to finish.
/// The gate is not re-entrant: a body must not call `run` on the same gate. Callers must not
/// hold it across user interaction or unbounded waits.
actor FilterTransactionGate {
    static let shared = FilterTransactionGate()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
