import Foundation

/// Converts a normalized filter source into Safari content-blocker JSON.
///
/// Sprint 1 ships `PassthroughRuleCompiler` only (bundled test JSON → copy, no real parsing).
/// The SafariConverterLib-backed implementation lands once ADR-0001 (GPL-3.0 licensing
/// decision) resolves — this protocol boundary means that swap touches nothing outside
/// Compilation/.
///
/// Target: main app ONLY — never in a Content Blocker extension (6MB memory ceiling makes
/// real compilation there a non-starter regardless of which implementation this becomes).
/// The requirement is `nonisolated` — see Task 3's note on SWIFT_DEFAULT_ACTOR_ISOLATION.
protocol RuleCompiler: Sendable {
    /// Compiles raw filter source data into a `CompiledRuleSet`.
    /// Must run off the main actor for any non-trivial input size.
    nonisolated func compile(source: Data, filterID: String) async throws -> CompiledRuleSet
}

enum RuleCompilerError: Error {
    case invalidSource
}

/// Sprint 1 stub: treats `source` as already-valid Safari JSON and passes it through,
/// generating count-only statistics. Does NOT exercise NFR-01 (compile time / memory budget)
/// — there is no real compilation work happening yet. Do not report this implementation's
/// timings as NFR-01 verification.
struct PassthroughRuleCompiler: RuleCompiler {
    nonisolated func compile(source: Data, filterID: String) async throws -> CompiledRuleSet {
        guard !source.isEmpty else {
            throw RuleCompilerError.invalidSource
        }
        let start = Date()

        guard (try? JSONSerialization.jsonObject(with: source)) != nil else {
            throw RuleCompilerError.invalidSource
        }

        let ruleCount = try? estimateRuleCount(from: source)
        let duration = Date().timeIntervalSince(start)

        let stats = RuleStatistics(
            compileDuration: duration,
            rulesLoaded: ruleCount ?? 0,
            duplicatesRemoved: 0,
            unsupportedRuleCount: 0,
            memoryEstimateBytes: source.count,
            lastUpdated: Date()
        )

        return CompiledRuleSet(
            sourceFilterID: filterID,
            rawJSON: source,
            ruleCount: ruleCount ?? 0,
            statistics: stats
        )
    }

    private func estimateRuleCount(from data: Data) throws -> Int {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            return 0
        }
        return array.count
    }
}
