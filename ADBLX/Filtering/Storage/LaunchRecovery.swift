import Foundation
import OSLog

/// Puts back a transaction that died before its commit (`FilterStore.recoverInterruptedTransaction`),
/// first thing at launch, under the gate.
///
/// After a restore every blocker is marked pending and reloaded. The dead transaction may have
/// reloaded some of them already, so what Safari holds can differ from the restored files, and
/// which ones isn't recorded anywhere that survives the restore. This path is rare, so reloading
/// all four is simplest; marking them first means a reload that fails is retried like any other.
nonisolated enum LaunchRecovery {
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "LaunchRecovery")

    /// Returns whether a transaction was restored.
    @discardableResult
    static func run(
        store: FilterStore,
        reloader: ReloadCoordinator,
        extensionIdentifiers: GroupExtensionIdentifiers,
        gate: FilterTransactionGate = .shared,
        stateProvider: ContentBlockerStateProviding = AppCompositionRoot.makeContentBlockerStateProvider()
    ) async -> Bool {
        await gate.run {
            let restored: Bool
            do {
                restored = try await store.recoverInterruptedTransaction()
            } catch {
                // Left in place: the next launch, or the next snapshot, tries again.
                logger.error("interrupted transaction recovery failed")
                return false
            }
            guard restored else { return false }
            logger.notice("restored an interrupted transaction")
            let all = FilterGroup.allCases.map { extensionIdentifiers[$0] }
            let pending = PendingReloads(store: store, stateProvider: stateProvider)
            try? await pending.mark(all)
            await pending.record(after: await reloader.reload(extensionIdentifiers: all))
            return true
        }
    }
}
