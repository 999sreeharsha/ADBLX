// ADBLXTests/Filtering/ChecksumTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("Checksum")
struct ChecksumTests {
    @Test("produces the known SHA-256 hex digest for a known input")
    func knownDigest() {
        let digest = Checksum.sha256Hex(of: Data("abc".utf8))
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("verify passes when the file's hash matches the expected hex digest")
    func verifyPassesOnMatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("payload.txt")
        try Data("abc".utf8).write(to: fileURL)

        try Checksum.verify(fileURL: fileURL, against: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("verify throws ChecksumError.mismatch when the file's hash doesn't match")
    func verifyThrowsOnMismatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("payload.txt")
        try Data("abc".utf8).write(to: fileURL)

        #expect(throws: ChecksumError.mismatch(
            expected: "0000000000000000000000000000000000000000000000000000000000000000",
            actual: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )) {
            try Checksum.verify(
                fileURL: fileURL,
                against: "0000000000000000000000000000000000000000000000000000000000000000"
            )
        }
    }

    // A list is hashed from disk in chunks, so verify never holds a whole list in memory.
    @Test("hashing a file in chunks gives the same digest as hashing it in memory", arguments: [0, 5, 7, 23])
    func chunkedFileDigestMatches(size: Int) throws {
        let data = Data((0..<size).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunked-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // 7-byte chunks: empty, under one chunk, exactly one, and several plus a remainder.
        #expect(try Checksum.sha256Hex(ofFileAt: url, chunkSize: 7) == Checksum.sha256Hex(of: data))
    }
}
