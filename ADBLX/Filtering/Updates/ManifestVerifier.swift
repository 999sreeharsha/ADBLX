import CryptoKit
import Foundation

/// Why a downloaded manifest was refused. Each case is a fixed code, safe to log
/// (`docs/Architecture/Logging.md`); never log the URL or an id with it.
nonisolated enum ManifestRejection: Error, Equatable {
    case signature, malformed, versionFormat, rollback, belowMinimum, id, duplicate, sourceURL
    /// Over `ManifestClient.maxManifestBytes`; raised by the client, before verification.
    case size
}

nonisolated enum ManifestVerdict: Equatable {
    case accepted(FilterManifest)
    /// Same version and same content as the cached manifest: handled like a 304.
    case unchanged
}

/// `manifestVersion` is a UTC timestamp, `YYYY-MM-DDTHH:MM:SSZ` (ManifestTrust.md, Rollback).
nonisolated enum ManifestVersionFormat {
    private static let timestamp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
    private static let dateOnly = /^\d{4}-\d{2}-\d{2}$/

    /// For an incoming manifest: only the full timestamp is accepted.
    static func strictDate(_ version: String) -> Date? {
        guard version.wholeMatch(of: timestamp) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        // The round trip rejects values the parser would roll over, such as 2026-02-30.
        guard let date = formatter.date(from: version), formatter.string(from: date) == version else { return nil }
        return date
    }

    /// For the cached version and the built-in minimum, which may still be date-only (the
    /// format before 2026-11-06): a date counts as that day at 00:00:00Z.
    static func lenientDate(_ version: String) -> Date? {
        if version.wholeMatch(of: dateOnly) != nil {
            return strictDate(version + "T00:00:00Z")
        }
        return strictDate(version)
    }
}

/// Checks a downloaded manifest before anything in it is used: the signature over the exact
/// bytes first, then every rule over the whole manifest. Any failure rejects all of it.
/// See docs/Security/ManifestTrust.md, "What the app checks, in order".
nonisolated struct ManifestVerifier {
    /// Production passes `ManifestTrust.pinnedPublicKeys`; tests pass their own.
    var trustedKeys: [P256.Signing.PublicKey]
    var allowedBases: [URL]
    var builtInMinimum: Date

    private static let idPattern = /^[a-z0-9][a-z0-9-]{0,63}$/

    /// The Publisher's format: base64 of a 64-byte raw (r ‖ s) ECDSA P-256 signature, then a newline.
    static func signatureIsValid(manifest: Data, signatureFile: Data, trustedKeys: [P256.Signing.PublicKey]) -> Bool {
        let encoded = String(decoding: signatureFile, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: encoded), raw.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return trustedKeys.contains { $0.isValidSignature(signature, for: manifest) }
    }

    func verify(
        manifest data: Data, signatureFile: Data, from manifestURL: URL, cached: FilterManifest?
    ) throws(ManifestRejection) -> ManifestVerdict {
        guard Self.signatureIsValid(manifest: data, signatureFile: signatureFile, trustedKeys: trustedKeys) else {
            throw .signature
        }
        guard let manifest = try? JSONDecoder().decode(FilterManifest.self, from: data) else { throw .malformed }

        guard let version = ManifestVersionFormat.strictDate(manifest.manifestVersion) else { throw .versionFormat }
        guard version >= builtInMinimum else { throw .belowMinimum }
        // A cached version that isn't a date at all predates the format; the minimum still applies.
        if let cached, let cachedVersion = ManifestVersionFormat.lenientDate(cached.manifestVersion) {
            if version < cachedVersion { throw .rollback }
            if version == cachedVersion {
                // Every field but the version string, already compared as a time (a date-only
                // cached value equals midnight). A new manifest field is covered automatically.
                var sameVersion = cached
                sameVersion.manifestVersion = manifest.manifestVersion
                guard manifest == sameVersion else { throw .rollback }
                return .unchanged
            }
        }

        var seen = Set<String>()
        for entry in manifest.entries {
            guard entry.id.wholeMatch(of: Self.idPattern) != nil else { throw .id }
            guard seen.insert(entry.id).inserted else { throw .duplicate }
        }

        let directory = manifestURL.deletingLastPathComponent().absoluteString
        guard manifestURL.scheme == "https",
              allowedBases.contains(where: { Self.withTrailingSlash($0.absoluteString) == directory }) else {
            throw .sourceURL
        }
        for entry in manifest.entries {
            let expected = "\(directory)filters/\(entry.group.rawValue)/\(entry.id).txt"
            guard entry.sourceURL.scheme == "https", entry.sourceURL.absoluteString == expected else { throw .sourceURL }
        }
        return .accepted(manifest)
    }

    private static func withTrailingSlash(_ string: String) -> String {
        string.hasSuffix("/") ? string : string + "/"
    }
}
