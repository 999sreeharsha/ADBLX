import Foundation
import CryptoKit

/// sha256 helper. Wired in this sprint per the metadata model, but not yet exercised in
/// anger — checksum verification against downloaded lists activates in Part 10 (FR-04).
///
/// `nonisolated`: the ADBLX target defaults unannotated declarations to @MainActor
/// (SWIFT_DEFAULT_ACTOR_ISOLATION), and this is called from off-main-actor pipeline code.
enum Checksum {
    nonisolated static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes a file `chunkSize` bytes at a time, so a list is never held whole in memory just
    /// to check it.
    nonisolated static func sha256Hex(ofFileAt url: URL, chunkSize: Int = 64 * 1_024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compares the SHA-256 of `fileURL`, read in chunks, against `expectedHex`.
    nonisolated static func verify(fileURL: URL, against expectedHex: String) throws {
        let actual = try sha256Hex(ofFileAt: fileURL)
        guard actual == expectedHex else {
            throw ChecksumError.mismatch(expected: expectedHex, actual: actual)
        }
    }
}

enum ChecksumError: Error, Equatable {
    case mismatch(expected: String, actual: String)
}
