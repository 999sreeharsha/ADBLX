import CryptoKit
import Foundation

/// What the app trusts a filter manifest from. See docs/Security/ManifestTrust.md.
nonisolated enum ManifestTrust {
    /// K1 (Secure Enclave) and K2 (offline file), base64 raw P-256, as `publisher keygen` prints
    /// them. Pinned 2026-11-21. Keep one quoted key per line:
    /// `Scripts/check-manifest-trust.sh` reads this list and fails an archive without both.
    static let productionPublicKeys: [String] = [
        "qxqESy6v3djL4Nh8RYL+Y0sb8Htav7t0kLd1e+C6pN0DldrCptoEi5VjZA6HhXujqP/KVNsFSFwJ6VeADEOUFw==", // K1
        "2PiVSmbkdA10tLgpXdNJx6IQw+0qlSKFm2rOLRFxbSQXZY3QA/oSkTMKgbW9raXuy3PzFF4wwSYKmowpUdSn8A==", // K2
    ]

    /// Moving the site means adding the new base in a release *before* the move.
    static let allowedBases = [URL(string: "https://999sreeharsha.github.io/ADBLX")!]

    /// What the app checks every downloaded manifest with. Only tests pass other keys.
    static func verifier(trustedKeys: [P256.Signing.PublicKey] = pinnedPublicKeys) -> ManifestVerifier {
        ManifestVerifier(trustedKeys: trustedKeys, allowedBases: allowedBases, builtInMinimum: BundledManifest.minimumVersion())
    }

    static var pinnedPublicKeys: [P256.Signing.PublicKey] {
        (productionPublicKeys + debugPublicKeys).compactMap { encoded in
            Data(base64Encoded: encoded).flatMap { try? P256.Signing.PublicKey(rawRepresentation: $0) }
        }
    }
}
