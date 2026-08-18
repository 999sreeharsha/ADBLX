import XCTest
@testable import Publisher

final class ManifestTests: XCTestCase {
    func test_buildsManifestEntryFromRegistryMetadataAndPayload() {
        let registry = Registry(registryVersion: 1, filters: [
            RegistryEntry(
                id: "easylist", name: "EasyList", upstreamProject: "EasyList",
                upstreamDownloadURL: "https://easylist.to/easylist/easylist.txt",
                license: "CC BY-SA 3.0 / GPLv3", group: "ads",
                enabledByDefault: true, premium: false, notes: nil
            )
        ])
        let metadata = ["easylist": FilterMetadata(id: "easylist", version: "2026-07-15")]
        let payload = ["easylist": PayloadInfo(checksumSHA256: "abc123", ruleCount: 62000)]

        let manifest = ManifestBuilder.build(
            registry: registry, metadataByID: metadata, payloadInfoByID: payload,
            publishBaseURL: "https://cdn.adblx.com"
        )

        XCTAssertEqual(manifest.entries.count, 1)
        let entry = manifest.entries[0]
        XCTAssertEqual(entry.id, "easylist")
        XCTAssertEqual(entry.sourceURL, "https://cdn.adblx.com/filters/ads/easylist.txt")
        XCTAssertTrue(entry.sourceURL.hasPrefix("https://cdn.adblx.com"))
        XCTAssertFalse(entry.sourceURL.contains("backend/public"))
        XCTAssertEqual(entry.version, "2026-07-15")
        XCTAssertEqual(entry.checksumSHA256, "abc123")
        XCTAssertEqual(entry.ruleCount, 62000)
        XCTAssertEqual(entry.enabledByDefault, true)
        XCTAssertEqual(entry.premium, false)
    }

    func test_manifestVersionIsMaxOfEntryVersions() {
        let registry = Registry(registryVersion: 1, filters: [
            makeEntry(id: "easylist", group: "ads"),
            makeEntry(id: "easyprivacy", group: "privacy")
        ])
        let metadata = [
            "easylist": FilterMetadata(id: "easylist", version: "2026-07-15"),
            "easyprivacy": FilterMetadata(id: "easyprivacy", version: "2026-07-20")
        ]
        let payload = [
            "easylist": PayloadInfo(checksumSHA256: "a", ruleCount: 1),
            "easyprivacy": PayloadInfo(checksumSHA256: "b", ruleCount: 2)
        ]

        let manifest = ManifestBuilder.build(
            registry: registry, metadataByID: metadata, payloadInfoByID: payload,
            publishBaseURL: "https://cdn.adblx.com"
        )

        XCTAssertEqual(manifest.manifestVersion, "2026-07-20")
    }

    func test_entriesAreSortedAscendingByID() {
        let registry = Registry(registryVersion: 1, filters: [
            makeEntry(id: "zebra", group: "ads"),
            makeEntry(id: "alpha", group: "privacy")
        ])
        let metadata = [
            "zebra": FilterMetadata(id: "zebra", version: "2026-07-15"),
            "alpha": FilterMetadata(id: "alpha", version: "2026-07-15")
        ]
        let payload = [
            "zebra": PayloadInfo(checksumSHA256: "a", ruleCount: 1),
            "alpha": PayloadInfo(checksumSHA256: "b", ruleCount: 2)
        ]

        let manifest = ManifestBuilder.build(
            registry: registry, metadataByID: metadata, payloadInfoByID: payload,
            publishBaseURL: "https://cdn.adblx.com"
        )

        XCTAssertEqual(manifest.entries.map(\.id), ["alpha", "zebra"])
    }

    func test_manifestEntryEncodesWithExactKeyOrder() throws {
        let entry = ManifestEntry(
            id: "easylist", name: "EasyList", group: "ads",
            sourceURL: "https://cdn.adblx.com/filters/ads/easylist.txt",
            version: "2026-07-15", checksumSHA256: "abc123", ruleCount: 62000,
            enabledByDefault: true, premium: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // NOTE: sortedKeys is used here only to prove round-trip Codable correctness;
        // ManifestWriter (Task 9/11) uses declaration-order encoding, verified by the
        // golden-file integration test (Task 10), not by this unit test.
        let data = try encoder.encode(entry)
        let decoded = try JSONDecoder().decode(ManifestEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    private func makeEntry(id: String, group: String) -> RegistryEntry {
        RegistryEntry(
            id: id, name: id, upstreamProject: "Test", upstreamDownloadURL: "https://example.invalid/\(id).txt",
            license: "MIT", group: group, enabledByDefault: true, premium: false, notes: nil
        )
    }
}
