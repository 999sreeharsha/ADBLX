import Foundation

/// Consecutive manifest rejections this launch, for the DEBUG diagnostics screen. In memory
/// only: it needs to survive the session, not a relaunch.
nonisolated final class ManifestRejectionLog: @unchecked Sendable {
    static let shared = ManifestRejectionLog()

    private let lock = NSLock()
    private var count = 0
    private var reason: ManifestRejection?

    var consecutive: Int { lock.withLock { count } }
    var lastReason: ManifestRejection? { lock.withLock { reason } }

    func recordRejection(_ rejection: ManifestRejection) {
        lock.withLock {
            count += 1
            reason = rejection
        }
    }

    /// Any manifest the client returns, including a 304, ends the run of rejections.
    func recordAccepted() {
        lock.withLock {
            count = 0
            reason = nil
        }
    }
}
