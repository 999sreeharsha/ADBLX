import Testing
import Foundation
@testable import ADBLX

@Suite("ManifestStore", .serialized)
struct ManifestStoreTests {
    private func sampleManifest() -> FilterManifest {
        let entry = FilterManifest.Entry(
            id: "easylist", name: "EasyList", group: .ads,
            sourceURL: URL(string: "https://example.com/easylist.txt")!,
            version: "2026-07-18", checksumSHA256: "abc123", ruleCount: 100,
            enabledByDefault: true, premium: false
        )
        return FilterManifest(manifestVersion: "1", entries: [entry])
    }

    @Test("load returns nil when nothing has been saved yet")
    func loadReturnsNilInitially() async throws {
        let filterStore = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let manifestStore = ManifestStore(filterStore: filterStore)

        // Ensure a clean slate: remove any manifest.json left by a previous run.
        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))

        let cached = try await manifestStore.load()
        #expect(cached == nil)
    }

    @Test("save then load round-trips the manifest and ETag byte-for-byte")
    func saveThenLoadRoundTrips() async throws {
        let filterStore = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let manifestStore = ManifestStore(filterStore: filterStore)
        let manifest = sampleManifest()

        try await manifestStore.save(manifest, etag: "\"etag-value\"")
        let cached = try await manifestStore.load()

        #expect(cached == CachedManifest(manifest: manifest, etag: "\"etag-value\""))

        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
    }

    @Test("save with a nil ETag round-trips a nil ETag")
    func saveWithNilETagRoundTrips() async throws {
        let filterStore = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let manifestStore = ManifestStore(filterStore: filterStore)
        let manifest = sampleManifest()

        try await manifestStore.save(manifest, etag: nil)
        let cached = try await manifestStore.load()

        #expect(cached == CachedManifest(manifest: manifest, etag: nil))

        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
    }
}
