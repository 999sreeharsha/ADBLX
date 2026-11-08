import Foundation

/// The filter work at launch, in order, run detached from the first frame. Kept as steps so a
/// test can check the order: recovering an interrupted transaction must come before anything
/// else reads or writes the filter directories.
nonisolated struct LaunchSequence: Sendable {
    var recoverInterruptedTransaction: @Sendable () async -> Void
    /// Entitlement, the initial rules, the web extension.
    var bootstrap: @Sendable () async -> Void
    var reconcile: @Sendable () async -> Void
    var recompile: @Sendable () async -> Void
    /// Returns whether the throttled update ran.
    var update: @Sendable () async -> Bool
    var afterUpdate: @Sendable () async -> Void

    func run() async {
        await recoverInterruptedTransaction()
        await bootstrap()
        await reconcile()
        await recompile()
        guard await update() else { return }
        await afterUpdate()
    }
}
