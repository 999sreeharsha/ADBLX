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
    ///
    /// Gated solely by `ManifestStore.load() == nil` (Sprint 8.0 Commit 1) — once the first
    /// production update commits a cached manifest, this never writes again. No additional
    /// bootstrap flag is introduced.
    @discardableResult
    nonisolated static func ensureInitialRulesInstalled(
        pipeline: FilterPipeline,
        manifestStore: ManifestStore
    ) async -> Bool {
        do {
            if try await manifestStore.load() != nil {
                logger.info("Cached manifest present — skipping bundled snapshot bootstrap")
                return false
            }
        } catch {
            logger.error("ManifestStore.load() failed during bootstrap gate check: \(error, privacy: .public)")
            return false
        }

        do {
            let result = try await pipeline.installBundledSnapshotIfNeeded()
            logger.info("Filter pipeline installed \(result.installedRuleCount) rule(s) for \(result.group.rawValue, privacy: .public)")
            return true
        } catch {
            logger.error("Filter pipeline install failed: \(error, privacy: .public)")
            return false
        }
    }
}
