import Foundation

/// Contents of `Compiled/<Group>.sources.json`, written right after `Compiled/<Group>.json`.
/// Lets a reconcile compare what built the rules with `installed_filters.json`, and lets an
/// extension log a count, without decoding the rules (up to about 150K of them).
nonisolated struct CompiledSources: Codable, Equatable, Sendable {
    /// The one source compiled without being recorded as installed: `syncAllowlist`'s bundled
    /// Ads fallback when nothing is installed. Not drift.
    static let uninstalledFallbackID = "ads-bundled"

    /// Bump whenever the compiler's output can change for the same input (`SafariRuleGenerator`,
    /// `NativeABPRuleCompiler`, the partitioner): every installed group is then recompiled at
    /// the next launch (`FilterPipeline.recompileIfCompilerChanged`).
    static let currentCompilerVersion = 1

    /// SHA-256 of the compiler's sources at `currentCompilerVersion`.
    /// `CompilerSourceFingerprintTests` fails when they change, as a reminder to bump the version.
    static let compilerFingerprint = (version: 1, sha256: "962d1e4e0661cbfc380eca6a100bd7e8ff7a6843dac8981414b20fb4c2460288")

    var sourceIDs: [String]
    /// Size of the rules file this sidecar describes. A mismatch means a crash between the two
    /// writes, which the source IDs can't show. An mtime wouldn't: the atomic rename keeps the
    /// temp file's.
    var compiledByteCount: Int
    var ruleCount: Int
    /// The `currentCompilerVersion` that wrote these rules; `nil` in sidecars written before it
    /// was recorded, which counts as another version.
    var compilerVersion: Int?

    static func rulesFilename(for group: FilterGroup) -> String {
        "\(group.rawValue.capitalized).json"
    }

    static func filename(for group: FilterGroup) -> String {
        "\(group.rawValue.capitalized).sources.json"
    }
}
