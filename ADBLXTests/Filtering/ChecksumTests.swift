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
}
