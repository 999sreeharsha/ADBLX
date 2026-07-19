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
}
