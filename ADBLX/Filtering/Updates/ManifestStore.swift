import Foundation

/// The cached manifest plus the HTTP ETag it was fetched with, persisted as one file.
/// ETag is transport metadata, not part of the manifest's meaning — kept as a sibling
/// field here rather than added to `FilterManifest` itself, so `FilterManifest` stays
/// representable from any source (bundle, disk fixture, import), not just the network.
struct CachedManifest: Codable, Equatable {
    var manifest: FilterManifest
    var etag: String?
    /// False for a cache written before manifest signatures were checked (2026-11-07). Its
    /// ETag is dropped on load, so the next fetch is a full 200 that goes through
    /// verification instead of a 304 that would keep an unverified manifest.
    var signatureVerified: Bool

    init(manifest: FilterManifest, etag: String?, signatureVerified: Bool = true) {
        self.manifest = manifest
        self.etag = etag
        self.signatureVerified = signatureVerified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try container.decode(FilterManifest.self, forKey: .manifest)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        signatureVerified = try container.decodeIfPresent(Bool.self, forKey: .signatureVerified) ?? false
    }
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
        guard var cached = try await loadAsStored() else { return nil }
        if !cached.signatureVerified {
            cached.etag = nil
        }
        return cached
    }

    /// Only ever called with a manifest that passed `ManifestVerifier`.
    func save(_ manifest: FilterManifest, etag: String?) async throws {
        try await write(CachedManifest(manifest: manifest, etag: etag, signatureVerified: true))
    }

    /// Forces the next fetch to be unconditional, keeping the manifest and its verified mark.
    func clearETag() async throws {
        guard var cached = try await loadAsStored() else { return }
        cached.etag = nil
        try await write(cached)
    }

    private func loadAsStored() async throws -> CachedManifest? {
        let data: Data
        do {
            data = try await filterStore.read(Self.filename, in: .metadata)
        } catch {
            return nil
        }
        return try JSONDecoder().decode(CachedManifest.self, from: data)
    }

    private func write(_ cached: CachedManifest) async throws {
        try await filterStore.writeMetadata(try JSONEncoder().encode(cached), filename: Self.filename)
    }
}
