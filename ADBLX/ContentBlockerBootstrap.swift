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
        manifestStore: ManifestStore,
        isPremiumEntitled: Bool = false
    ) async -> Bool {
        do {
            if let _ = try await manifestStore.load() {
                // Through the same store the manifest came from, never the raw container.
                if let data = try? await manifestStore.filterStore.read("Ads.json", in: .compiled), data.count > 10_000 {
                    logger.info("Cached manifest and valid compiled rules present — skipping bundled snapshot bootstrap")
                    return false
                }
            }
        } catch {
            logger.error("ManifestStore.load() failed during bootstrap gate check: \(error, privacy: .public)")
        }

        do {
            let results = try await pipeline.installBundledSnapshotIfNeeded(includePremium: isPremiumEntitled)
            var logLines = ["=== SHIELD BLOCKING BASELINE ==="]
            var totalRules = 0
            for result in results {
                totalRules += result.installedRuleCount
                let durationStr = String(format: "%.3f", result.compileStatistics.compileDuration)
                let name = result.group.rawValue.capitalized
                let count = result.installedRuleCount
                let isSynthetic = count <= 100
                let sourceDesc = isSynthetic ? "bundled_fixture (FALLBACK)" : "bundled_corpus"
                logLines.append("• \(name): \(count) rules [source=\(sourceDesc)] in \(durationStr)s")
            }
            logLines.append("• Total active rules: \(totalRules)")
            logLines.append("================================")
            logger.info("\(logLines.joined(separator: "\n"), privacy: .public)")
            return true
        } catch {
            logger.error("Filter pipeline install failed: \(error, privacy: .public)")
            return false
        }
    }
}
