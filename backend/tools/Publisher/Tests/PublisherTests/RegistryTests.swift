import XCTest
@testable import Publisher

final class RegistryTests: XCTestCase {
    func test_decodesValidRegistry() throws {
        let json = """
        {
          "registryVersion": 1,
          "filters": [
            {
              "id": "easylist",
              "name": "EasyList",
              "upstreamProject": "EasyList",
              "upstreamDownloadURL": "https://easylist.to/easylist/easylist.txt",
              "license": "CC BY-SA 3.0 / GPLv3",
              "group": "ads",
              "enabledByDefault": true,
              "premium": false,
              "notes": null
            }
          ]
        }
        """
        let url = try Self.writeTempFile(contents: json)
        let registry = try RegistryLoader.load(from: url)

        XCTAssertEqual(registry.registryVersion, 1)
        XCTAssertEqual(registry.filters.count, 1)
        XCTAssertEqual(registry.filters[0].id, "easylist")
        XCTAssertEqual(registry.filters[0].name, "EasyList")
        XCTAssertEqual(registry.filters[0].group, "ads")
        XCTAssertEqual(registry.filters[0].enabledByDefault, true)
        XCTAssertEqual(registry.filters[0].premium, false)
        XCTAssertNil(registry.filters[0].notes)
    }

    func test_throwsOnMalformedJSON() throws {
        let url = try Self.writeTempFile(contents: "{ not valid json")
        XCTAssertThrowsError(try RegistryLoader.load(from: url)) { error in
            guard case RegistryLoaderError.malformedJSON = error else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
        }
    }

    func test_throwsOnUnsupportedRegistryVersion() throws {
        let json = """
        { "registryVersion": 2, "filters": [] }
        """
        let url = try Self.writeTempFile(contents: json)
        XCTAssertThrowsError(try RegistryLoader.load(from: url)) { error in
            guard case RegistryLoaderError.unsupportedRegistryVersion(let found, let supported) = error else {
                return XCTFail("expected unsupportedRegistryVersion, got \(error)")
            }
            XCTAssertEqual(found, 2)
            XCTAssertEqual(supported, 1)
        }
    }

    static func writeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
