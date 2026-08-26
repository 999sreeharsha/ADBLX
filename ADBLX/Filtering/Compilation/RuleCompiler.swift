import Foundation
import ADBLXShared

/// Converts a normalized, composed filter source into Safari content-blocker JSON.
///
/// Target: main app ONLY — never in a Content Blocker extension (6MB memory ceiling makes
/// real compilation there a non-starter).
protocol RuleCompiler: Sendable {
    /// Compiles `source` (ABP declarative text or pre-compiled JSON) into a
    /// `CompiledRuleSet` for `group`. Must run off the main actor.
    nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet
}

enum RuleCompilerError: Error {
    case invalidSource
}

/// Production compiler: utilizes `NativeABPRuleCompiler` from `ADBLXShared` to parse
/// standard ABP/AdGuard declarative filter lists into WebKit Safari Content Blocker JSON.
/// Also provides backward compatibility with pre-formatted JSON fixtures.
struct NativeRuleCompilerAdapter: RuleCompiler {
    nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
        if source.isEmpty || source == Data("[]".utf8) {
            let stats = RuleStatistics(
                compileDuration: 0.0001,
                rulesLoaded: 0,
                duplicatesRemoved: 0,
                unsupportedRuleCount: 0,
                memoryEstimateBytes: 2,
                lastUpdated: Date()
            )
            return CompiledRuleSet(group: group, rawJSON: Data("[]".utf8), ruleCount: 0, statistics: stats)
        }
        
        // If source is already a valid JSON array (e.g. bundled blockerList.json):
        if let array = (try? JSONSerialization.jsonObject(with: source)) as? [Any] {
            let stats = RuleStatistics(
                compileDuration: 0.001,
                rulesLoaded: array.count,
                duplicatesRemoved: 0,
                unsupportedRuleCount: 0,
                memoryEstimateBytes: source.count,
                lastUpdated: Date()
            )
            return CompiledRuleSet(group: group, rawJSON: source, ruleCount: array.count, statistics: stats)
        }
        
        // Real ABP Text Compilation
        do {
            let (jsonData, report) = try NativeABPRuleCompiler.compileToJSON(source: source, group: group.rawValue)
            let stats = RuleStatistics(
                compileDuration: report.compilationDurationSeconds,
                rulesLoaded: report.compiledRuleCount,
                duplicatesRemoved: 0,
                unsupportedRuleCount: report.skippedRulesCount,
                memoryEstimateBytes: jsonData.count,
                lastUpdated: Date()
            )
            return CompiledRuleSet(
                group: group,
                rawJSON: jsonData,
                ruleCount: report.compiledRuleCount,
                statistics: stats
            )
        } catch {
            throw RuleCompilerError.invalidSource
        }
    }
}

/// Backward compatibility passthrough compiler for testing.
struct PassthroughRuleCompiler: RuleCompiler {
    nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
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
            group: group,
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
