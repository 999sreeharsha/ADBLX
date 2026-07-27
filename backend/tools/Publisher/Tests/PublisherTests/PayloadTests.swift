import XCTest
import CryptoKit
@testable import Publisher

final class PayloadTests: XCTestCase {
    func test_computesChecksumMatchingSHA256() throws {
        let content = "||example.com^\n||ads.example.com^\n"
        let url = try Self.writeTempFile(contents: content)

        let info = try PayloadReader.read(fileAt: url)

        let expectedDigest = SHA256.hash(data: Data(content.utf8))
        let expectedHex = expectedDigest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(info.checksumSHA256, expectedHex)
    }

    func test_countsNonEmptyNonCommentLinesAsRules() throws {
        let content = """
        ! this is a comment
        ||example.com^

        ||ads.example.com^
        ! another comment
        """
        let url = try Self.writeTempFile(contents: content)

        let info = try PayloadReader.read(fileAt: url)

        XCTAssertEqual(info.ruleCount, 2)
    }

    func test_throwsWhenFileMissing() {
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.txt")
        XCTAssertThrowsError(try PayloadReader.read(fileAt: missingURL)) { error in
            guard case PayloadReaderError.fileNotFound = error else {
                return XCTFail("expected fileNotFound, got \(error)")
            }
        }
    }

    static func writeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
