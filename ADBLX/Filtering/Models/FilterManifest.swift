import Foundation

/// Mirrors the CDN-hosted `manifest.json` catalog (PRD §6.2).
/// Populated from the network starting in Part 10; for Sprint 1, loaded from a bundled
/// test fixture to exercise the rest of the pipeline without networking.
struct FilterManifest: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var group: FilterGroup
        var sourceURL: URL
        /// Date-based version string, e.g. "2026-07-15".
        var version: String
        var checksumSHA256: String
        var ruleCount: Int
        var enabledByDefault: Bool
        var premium: Bool
    }

    var manifestVersion: String
    var entries: [Entry]
}

enum FilterGroup: String, Codable, Equatable, CaseIterable {
    case ads
    case privacy
    case annoyances
    case regional
}
