import Foundation

/// Telemetry record detailing the outcome and breakdown of a filter compilation run.
public struct CompilationReport: Sendable, Equatable, Codable {
    public var totalLinesProcessed: Int
    public var compiledRuleCount: Int
    public var commentsAndHeadersCount: Int
    public var skippedRulesCount: Int
    public var deferredToWebExtensionCount: Int
    public var invalidRulesCount: Int
    public var badfilterCount: Int
    /// Rules dropped because every domain they named is unsupported by Safari (e.g. `site.*`).
    public var droppedUnsupportedDomainsCount: Int
    /// Rules dropped because all of their included domains were unsupported, leaving only
    /// exclusions; emitting them would widen a site-specific rule to every other site.
    public var droppedUnlessOnlyCount: Int
    /// Rules kept with some unsupported domains removed from a mixed list.
    public var trimmedDomainsRuleCount: Int
    public var unsupportedSemanticModifiers: [String: Int]
    public var compilationDurationSeconds: TimeInterval
    public var group: String

    public init(
        totalLinesProcessed: Int = 0,
        compiledRuleCount: Int = 0,
        commentsAndHeadersCount: Int = 0,
        skippedRulesCount: Int = 0,
        deferredToWebExtensionCount: Int = 0,
        invalidRulesCount: Int = 0,
        badfilterCount: Int = 0,
        droppedUnsupportedDomainsCount: Int = 0,
        droppedUnlessOnlyCount: Int = 0,
        trimmedDomainsRuleCount: Int = 0,
        unsupportedSemanticModifiers: [String: Int] = [:],
        compilationDurationSeconds: TimeInterval = 0,
        group: String = ""
    ) {
        self.totalLinesProcessed = totalLinesProcessed
        self.compiledRuleCount = compiledRuleCount
        self.commentsAndHeadersCount = commentsAndHeadersCount
        self.skippedRulesCount = skippedRulesCount
        self.deferredToWebExtensionCount = deferredToWebExtensionCount
        self.invalidRulesCount = invalidRulesCount
        self.badfilterCount = badfilterCount
        self.droppedUnsupportedDomainsCount = droppedUnsupportedDomainsCount
        self.droppedUnlessOnlyCount = droppedUnlessOnlyCount
        self.trimmedDomainsRuleCount = trimmedDomainsRuleCount
        self.unsupportedSemanticModifiers = unsupportedSemanticModifiers
        self.compilationDurationSeconds = compilationDurationSeconds
        self.group = group
    }
}
