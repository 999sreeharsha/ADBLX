import XCTest
@testable import Publisher

final class MetadataTests: XCTestCase {
    func test_loadsAllMetadataFilesInDirectory() throws {
        let dir = try Self.makeTempDirectory()
        try Self.writeMetadata(id: "easylist", version: "2026-07-15", in: dir)
        try Self.writeMetadata(id: "easyprivacy", version: "2026-07-16", in: dir)

        let results = try MetadataLoader.loadAll(from: dir)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.filename == "easylist.json" && $0.metadata.id == "easylist" && $0.metadata.version == "2026-07-15" })
        XCTAssertTrue(results.contains { $0.filename == "easyprivacy.json" && $0.metadata.id == "easyprivacy" && $0.metadata.version == "2026-07-16" })
    }

    func test_ignoresNonJSONFiles() throws {
        let dir = try Self.makeTempDirectory()
        try Self.writeMetadata(id: "easylist", version: "2026-07-15", in: dir)
        try "not metadata".write(to: dir.appendingPathComponent(".gitkeep"), atomically: true, encoding: .utf8)

        let results = try MetadataLoader.loadAll(from: dir)
        XCTAssertEqual(results.count, 1)
    }

    func test_emptyDirectoryProducesNoResults() throws {
        let dir = try Self.makeTempDirectory()
        let results = try MetadataLoader.loadAll(from: dir)
        XCTAssertEqual(results.count, 0)
    }

    static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeMetadata(id: String, version: String, in directory: URL) throws {
        let json = "{\"id\": \"\(id)\", \"version\": \"\(version)\"}"
        let url = directory.appendingPathComponent("\(id).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
    }
}
