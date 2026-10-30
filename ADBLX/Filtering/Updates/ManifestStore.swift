import Foundation

/// The cached manifest plus the HTTP ETag it was fetched with, persisted as one file.
/// ETag is transport metadata, not part of the manifest's meaning — kept as a sibling
/// field here rather than added to `FilterManifest` itself, so `FilterManifest` stays
/// representable from any source (bundle, disk fixture, import), not just the network.
struct CachedManifest: Codable, Equatable {
    var manifest: FilterManifest
    var etag: String?
}

/// Persists the cached manifest via `FilterStore`'s `Metadata` directory, consistent
/// with how `installed_filters.json` and `statistics.json` are already stored.
actor ManifestStore {
    private static let filename = "manifest.json"

    let filterStore: FilterStore

    init(filterStore: FilterStore) {
        self.filterStore = filterStore
    }

    /// Returns `nil` if nothing has been cached yet — not an error condition.
    func load() async throws -> CachedManifest? {
        let data: Data
        do {
            data = try await filterStore.read(Self.filename, in: .metadata)
        } catch {
            return nil
        }
        return try JSONDecoder().decode(CachedManifest.self, from: data)
    }

    func save(_ manifest: FilterManifest, etag: String?) async throws {
        let cached = CachedManifest(manifest: manifest, etag: etag)
        let data = try JSONEncoder().encode(cached)
        try await filterStore.writeMetadata(data, filename: Self.filename)
    }
}
