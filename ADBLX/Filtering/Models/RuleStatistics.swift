import Foundation

/// Compile/pipeline statistics for a single filter or a full compile pass.
///
/// PRIVACY CONSTRAINT (docs/Architecture/Logging.md): every field here must remain a count,
/// duration, or size estimate. Never add a field that could hold a rule body, domain,
/// hostname, or URL — including for debug builds. If you're tempted to log "which rules were
/// unsupported," log the *count* of unsupported rules, not their content.
struct RuleStatistics: Codable, Equatable {
    var compileDuration: TimeInterval
    var rulesLoaded: Int
    var duplicatesRemoved: Int
    var unsupportedRuleCount: Int
    var memoryEstimateBytes: Int
    var lastUpdated: Date
}
