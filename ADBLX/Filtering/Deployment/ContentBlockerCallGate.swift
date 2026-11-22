import Foundation
import os

/// Every `SFContentBlockerManager` call in the app (state checks and reloads) goes through
/// `ContentBlockerCallGate.shared`, one call at a time.
///
/// Why: the manager sets up its connection to Safari lazily on the first call, and that setup
/// isn't thread-safe. Two first calls at once resume the same XPC connection twice, and iOS kills
/// the app (`BUG IN CLIENT OF LIBDISPATCH: Over-resume of an object`; iPhone 14, 2026-11-22,
/// three threads inside `+[SFContentBlockerManager _contentBlockerLoaderConnection]`).
///
/// A call holds the gate until its completion fires or `timeout` passes, whichever comes first,
/// because the manager can drop a completion without calling it. A timeout releases the gate
/// so later calls still run, and is counted in `timeoutReleases`. Waiters run in arrival order.
actor ContentBlockerCallGate {
    static let shared = ContentBlockerCallGate()

    enum Outcome<Value: Sendable>: Sendable {
        case answered(Value)
        case timedOut
    }

    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "ContentBlockerCallGate")

    private let timeoutCount = OSAllocatedUnfairLock(initialState: 0)
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many calls released the gate by timing out rather than by answering.
    nonisolated var timeoutReleases: Int { timeoutCount.withLock { $0 } }

    /// Runs `operation` and waits for the answer it passes to its callback, for at most `timeout`.
    /// A callback after the timeout is ignored.
    func call<Value: Sendable>(
        timeout: Duration,
        _ operation: (_ answer: @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Outcome<Value> {
        await acquire()
        defer { release() }
        let resumeGuard = ResumeOnce()
        var timer: Task<Void, Never>?
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<Value>, Never>) in
            // Unstructured, not a TaskGroup child: a group waits for all its children, which
            // would make the timeout wait for an answer that may never come.
            timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                guard resumeGuard.markAndCheckFirst() else { return }
                continuation.resume(returning: .timedOut)
            }
            operation { value in
                guard resumeGuard.markAndCheckFirst() else { return }
                continuation.resume(returning: .answered(value))
            }
        }
        timer?.cancel()
        if case .timedOut = outcome {
            let count = timeoutCount.withLock { $0 += 1; return $0 }
            let limit = String(describing: timeout)
            Self.logger.error(
                "content blocker call timed out after \(limit, privacy: .public); gate released (\(count) so far)"
            )
        }
        return outcome
    }

    private func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate straight to the next waiter, so nobody can slip in between.
    private func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
