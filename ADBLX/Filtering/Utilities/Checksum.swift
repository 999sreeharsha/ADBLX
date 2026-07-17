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
}
