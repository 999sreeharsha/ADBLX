import Foundation

/// The manifest the bundled lists came from, shipped as `Resources/Filters/bundled-manifest.json`
/// and refreshed before each archive by `Scripts/refresh-bundled-manifest.sh`. Its version is
/// the oldest manifest the app accepts, so a fresh install can't be served an older one that
/// is still validly signed (docs/Security/ManifestTrust.md, Rollback).
nonisolated enum BundledManifest {
    private static let resourceName = "bundled-manifest"

    static func load(from bundle: Bundle = .main) -> FilterManifest? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FilterManifest.self, from: data)
    }

    /// `.distantFuture` when the bundled manifest is missing or unreadable, so every manifest
    /// is rejected rather than any being accepted with no floor. A test keeps it present.
    static func minimumVersion(in bundle: Bundle = .main) -> Date {
        load(from: bundle).flatMap { ManifestVersionFormat.lenientDate($0.manifestVersion) } ?? .distantFuture
    }
}
