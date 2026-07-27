import XCTest
@testable import Publisher

final class AtomicFileWriterTests: XCTestCase {
    func test_writesDataToDestination() throws {
        let dir = try MetadataTests.makeTempDirectory()
        let destination = dir.appendingPathComponent("output.json")
        let writer = AtomicFileWriter()

        try writer.write(Data("hello".utf8), to: destination)

        let contents = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(contents, "hello")
    }

    func test_overwritesExistingFileAtomically() throws {
        let dir = try MetadataTests.makeTempDirectory()
        let destination = dir.appendingPathComponent("output.json")
        try "old contents".write(to: destination, atomically: true, encoding: .utf8)
        let writer = AtomicFileWriter()

        try writer.write(Data("new contents".utf8), to: destination)

        let contents = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(contents, "new contents")
    }

    func test_leavesNoTempFilesBehindOnSuccess() throws {
        let dir = try MetadataTests.makeTempDirectory()
        let destination = dir.appendingPathComponent("output.json")
        let writer = AtomicFileWriter()

        try writer.write(Data("hello".utf8), to: destination)

        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(remainingFiles, ["output.json"])
    }
}
