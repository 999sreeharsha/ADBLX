import Foundation

/// Contents of `Compiled/<Group>.sources.json`, written right after `Compiled/<Group>.json`.
/// Lets a reconcile compare what built the rules with `installed_filters.json`, and lets an
/// extension log a count, without decoding the rules (up to about 150K of them).
nonisolated struct CompiledSources: Codable, Equatable, Sendable {
    /// The one source compiled without being recorded as installed: `syncAllowlist`'s bundled
    /// Ads fallback when nothing is installed. Not drift.
    static let uninstalledFallbackID = "ads-bundled"

    var sourceIDs: [String]
    var compiledSHA256: String
    var ruleCount: Int

    static func rulesFilename(for group: FilterGroup) -> String {
        "\(group.rawValue.capitalized).json"
    }

    static func filename(for group: FilterGroup) -> String {
        "\(group.rawValue.capitalized).sources.json"
    }
}
