import XCTest
@testable import Publisher

final class ManifestJSONWriterTests: XCTestCase {
    func test_singleEntryProducesExactKeyOrderAndFormatting() {
        let manifest = Manifest(
            manifestVersion: "2026-07-15",
            entries: [
                ManifestEntry(
                    id: "easylist", name: "EasyList", group: "ads",
                    sourceURL: "https://cdn.adblx.com/filters/ads/easylist.txt",
                    version: "2026-07-15", checksumSHA256: "abc123", ruleCount: 62000,
                    enabledByDefault: true, premium: false
                )
            ]
        )

        let data = ManifestJSONWriter.write(manifest)
        let text = String(decoding: data, as: UTF8.self)

        let expected = """
        {
          "manifestVersion": "2026-07-15",
          "entries": [
            {
              "id": "easylist",
              "name": "EasyList",
              "group": "ads",
              "sourceURL": "https://cdn.adblx.com/filters/ads/easylist.txt",
              "version": "2026-07-15",
              "checksumSHA256": "abc123",
              "ruleCount": 62000,
              "enabledByDefault": true,
              "premium": false
            }
          ]
        }

        """

        XCTAssertEqual(text, expected)
    }

    func test_multipleEntriesMaintainGivenOrderWithoutResorting() {
        let manifest = Manifest(
            manifestVersion: "2026-07-20",
            entries: [
                ManifestEntry(
                    id: "zebra", name: "Zebra", group: "ads",
                    sourceURL: "https://cdn.adblx.com/filters/ads/zebra.txt",
                    version: "2026-07-15", checksumSHA256: "aaa", ruleCount: 1,
                    enabledByDefault: true, premium: false
                ),
                ManifestEntry(
                    id: "alpha", name: "Alpha", group: "privacy",
                    sourceURL: "https://cdn.adblx.com/filters/privacy/alpha.txt",
                    version: "2026-07-20", checksumSHA256: "bbb", ruleCount: 2,
                    enabledByDefault: false, premium: true
                )
            ]
        )

        let data = ManifestJSONWriter.write(manifest)
        let text = String(decoding: data, as: UTF8.self)

        // Writer must NOT re-sort — "zebra" (as given) must appear before "alpha".
        let zebraRange = text.range(of: "\"id\": \"zebra\"")
        let alphaRange = text.range(of: "\"id\": \"alpha\"")
        XCTAssertNotNil(zebraRange)
        XCTAssertNotNil(alphaRange)
        if let zebraRange, let alphaRange {
            XCTAssertLessThan(zebraRange.lowerBound, alphaRange.lowerBound)
        }
    }

    func test_stringValuesAreEscapedForQuotesAndBackslashes() {
        let manifest = Manifest(
            manifestVersion: "2026-07-15",
            entries: [
                ManifestEntry(
                    id: "weird-id", name: "Name with \"quotes\" and \\backslash\\", group: "ads",
                    sourceURL: "https://cdn.adblx.com/filters/ads/weird-id.txt",
                    version: "2026-07-15", checksumSHA256: "abc123", ruleCount: 1,
                    enabledByDefault: true, premium: false
                )
            ]
        )

        let data = ManifestJSONWriter.write(manifest)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\"name\": \"Name with \\\"quotes\\\" and \\\\backslash\\\\\""))

        // Round-trip through JSONDecoder to prove the escaping is actually valid JSON.
        let decoded = try! JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(decoded.entries[0].name, "Name with \"quotes\" and \\backslash\\")
    }

    func test_emptyEntriesProducesEmptyArray() {
        let manifest = Manifest(manifestVersion: "2026-07-15", entries: [])

        let data = ManifestJSONWriter.write(manifest)
        let text = String(decoding: data, as: UTF8.self)

        let expected = """
        {
          "manifestVersion": "2026-07-15",
          "entries": []
        }

        """
        XCTAssertEqual(text, expected)
    }
}
