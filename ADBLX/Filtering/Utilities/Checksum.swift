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

    /// Reads `fileURL` and compares its SHA-256 against `expectedHex`. Callers holding a
    /// `URL` (e.g. a downloaded filter's temp file) never need to load the whole file into
    /// `Data` themselves just to verify it — this does that internally.
    nonisolated static func verify(fileURL: URL, against expectedHex: String) throws {
        let data = try Data(contentsOf: fileURL)
        let actual = sha256Hex(of: data)
        guard actual == expectedHex else {
            throw ChecksumError.mismatch(expected: expectedHex, actual: actual)
        }
    }
}

enum ChecksumError: Error, Equatable {
    case mismatch(expected: String, actual: String)
}
