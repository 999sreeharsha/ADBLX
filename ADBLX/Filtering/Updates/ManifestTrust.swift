import CryptoKit
import Foundation

/// What the app trusts a filter manifest from. See docs/Security/ManifestTrust.md.
nonisolated enum ManifestTrust {
    /// K1 (Secure Enclave) and K2 (offline file), base64 raw P-256, as `publisher keygen` prints
    /// them. Empty until the owner generates the keys; until then every manifest is rejected and
    /// the app stays on its bundled lists. Keep one quoted key per line:
    /// `Scripts/check-manifest-trust.sh` reads this list and fails an archive without both.
    static let productionPublicKeys: [String] = [
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
