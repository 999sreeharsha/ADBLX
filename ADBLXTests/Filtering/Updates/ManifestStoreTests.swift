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
        let filterStore = FilterStore.temporary()
        let manifestStore = ManifestStore(filterStore: filterStore)

        // Ensure a clean slate: remove any manifest.json left by a previous run.
        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))

        let cached = try await manifestStore.load()
        #expect(cached == nil)
    }

    @Test("save then load round-trips the manifest and ETag byte-for-byte")
    func saveThenLoadRoundTrips() async throws {
        let filterStore = FilterStore.temporary()
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
        let filterStore = FilterStore.temporary()
        let manifestStore = ManifestStore(filterStore: filterStore)
        let manifest = sampleManifest()

        try await manifestStore.save(manifest, etag: nil)
        let cached = try await manifestStore.load()

        #expect(cached == CachedManifest(manifest: manifest, etag: nil))

        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
    }

    // Only a verified manifest is ever saved, so a saved one is marked verified.
    @Test("A saved manifest is marked as signature-verified")
    func savedManifestIsVerified() async throws {
        let manifestStore = ManifestStore(filterStore: FilterStore.temporary())

        try await manifestStore.save(sampleManifest(), etag: "\"v1\"")

        #expect(try await manifestStore.load()?.signatureVerified == true)
    }

    // A 304 against a cache from before verification would keep an unverified manifest forever.
    @Test("A cache written before verification existed loads without its ETag and unverified")
    func cacheFromBeforeVerificationDropsItsETag() async throws {
        let filterStore = FilterStore.temporary()
        let manifestStore = ManifestStore(filterStore: filterStore)
        struct OldCachedManifest: Encodable {
            var manifest: FilterManifest
            var etag: String?
        }
        let old = try JSONEncoder().encode(OldCachedManifest(manifest: sampleManifest(), etag: "\"old\""))
        try await filterStore.writeMetadata(old, filename: "manifest.json")

        let cached = try #require(try await manifestStore.load())

        #expect(cached.etag == nil)
        #expect(cached.signatureVerified == false)
        #expect(cached.manifest == sampleManifest())
    }

    @Test("Clearing the ETag keeps the manifest and its verified mark")
    func clearETagKeepsTheVerifiedMark() async throws {
        let manifestStore = ManifestStore(filterStore: FilterStore.temporary())
        try await manifestStore.save(sampleManifest(), etag: "\"v1\"")

        try await manifestStore.clearETag()

        #expect(try await manifestStore.load() == CachedManifest(manifest: sampleManifest(), etag: nil, signatureVerified: true))
    }

    @Test("Clearing the ETag of an unverified cache leaves it unverified")
    func clearETagLeavesAnUnverifiedCacheUnverified() async throws {
        let filterStore = FilterStore.temporary()
        let manifestStore = ManifestStore(filterStore: filterStore)
        struct OldCachedManifest: Encodable {
            var manifest: FilterManifest
            var etag: String?
        }
        try await filterStore.writeMetadata(
            try JSONEncoder().encode(OldCachedManifest(manifest: sampleManifest(), etag: "\"old\"")), filename: "manifest.json"
        )

        try await manifestStore.clearETag()

        #expect(try await manifestStore.load()?.signatureVerified == false)
    }
}
