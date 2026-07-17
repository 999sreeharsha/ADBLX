import Foundation
import OSLog

/// Sprint 0 had this type copy bundled JSON and call SFContentBlockerManager directly.
/// Sprint 1 replaces both with a single delegation into FilterPipeline, so FilterStore and
/// ReloadCoordinator become (and stay) the only types touching the App Group filesystem and
/// SFContentBlockerManager respectively.
enum ContentBlockerBootstrap {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ADBLX.ADBLX",
        category: "Bootstrap"
    )

    /// `nonisolated`: called from a detached, off-main-actor Task at launch — see the plan's
    /// Global Constraints note on SWIFT_DEFAULT_ACTOR_ISOLATION.
    @discardableResult
    nonisolated static func ensureInitialRulesInstalled(pipeline: FilterPipeline) async -> Bool {
        do {
            let result = try await pipeline.installBundledSnapshotIfNeeded()
            logger.info("Filter pipeline installed \(result.installedRuleCount) rule(s) for \(result.filterID, privacy: .public)")
            return true
        } catch {
            logger.error("Filter pipeline install failed: \(error, privacy: .public)")
            return false
        }
    }
}
