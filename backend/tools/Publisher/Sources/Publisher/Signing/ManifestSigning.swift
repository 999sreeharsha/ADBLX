import CryptoKit
import Foundation

/// Ed25519 signatures over the exact bytes of `manifest.json`, in `signatures/<sha256>.sig`: the
/// base64 of the 64-byte signature and a newline. The app verifies those same bytes against
/// its pinned public keys before parsing them. See `docs/Security/ManifestTrust.md`.
///
/// CryptoKit randomizes Ed25519 signatures, so the signature file differs between runs even
/// though the manifest does not. Every one of them verifies.
enum ManifestSigning {
    /// Named after the manifest's SHA-256, so a cached signature can only belong to the manifest
    /// whose bytes the app hashed. The manifest and signature are cached separately.
    static func signatureFilename(for manifest: Data) -> String {
        SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined() + ".sig"
    }

    static func signatureFile(for manifest: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
        let signature = try key.signature(for: manifest)
        return Data((signature.base64EncodedString() + "\n").utf8)
    }

    /// True when any trusted key verifies the signature. Two are pinned during a rotation.
    static func verify(manifest: Data, signatureFile: Data, trustedKeys: [Curve25519.Signing.PublicKey]) -> Bool {
        let text = String(decoding: signatureFile, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: text), signature.count == 64 else { return false }
        return trustedKeys.contains { $0.isValidSignature(signature, for: manifest) }
    }
}

/// Writing and signing the files the Pages deploy serves.
enum ManifestPublication {
    /// Signs the manifest as it is on disk, the bytes devices will download, and returns where the
    /// signature went. Earlier signatures stay: a device whose CDN edge still serves an older
    /// manifest needs that manifest's signature, and each is under 100 bytes.
    @discardableResult
    static func sign(manifestAt manifestURL: URL, key: Curve25519.Signing.PrivateKey, signaturesDirectory: URL) throws -> URL {
        let manifest = try Data(contentsOf: manifestURL)
        try FileManager.default.createDirectory(at: signaturesDirectory, withIntermediateDirectories: true)
        let signatureURL = signaturesDirectory.appendingPathComponent(ManifestSigning.signatureFilename(for: manifest))
        try AtomicFileWriter().write(try ManifestSigning.signatureFile(for: manifest, key: key), to: signatureURL)
        return signatureURL
    }
}

/// Errors carry no key material: CI shows thrown errors in its logs.
enum SigningKeyError: Error, Equatable, CustomStringConvertible {
    case missing
    case ambiguousSource
    case malformed
    case unreadable(path: String)
    case insideRepository(path: String)
    case alreadyExists(path: String)

    var description: String {
        switch self {
        case .missing:
            return "No signing key. Pass --signing-key-file or set \(SigningKeySource.environmentVariable)."
        case .ambiguousSource:
            return "Both --signing-key-file and \(SigningKeySource.environmentVariable) are set. Use one."
        case .malformed:
            return "The signing key isn't a base64 Ed25519 private key (32 bytes)."
        case .unreadable(let path):
            return "Couldn't read the signing key file at \(path)."
        case .insideRepository(let path):
            return "\(path) is inside the repository. Keep the signing key outside it, so it can't be committed."
        case .alreadyExists(let path):
            return "\(path) already exists. Refusing to overwrite a signing key."
        }
    }
}

/// The private key comes from outside the repository: a file path given on the command line, or
/// an environment variable (for CI, from its secret store). It is never printed.
enum SigningKeySource {
    static let environmentVariable = "ADBLX_MANIFEST_SIGNING_KEY"

    static func load(keyFile: URL?, environment: [String: String], repositoryRoot: URL) throws -> Curve25519.Signing.PrivateKey {
        let fromEnvironment = environment[environmentVariable].flatMap { $0.isEmpty ? nil : $0 }
        let encoded: String
        switch (keyFile, fromEnvironment) {
        case (nil, nil):
            throw SigningKeyError.missing
        case (.some, .some):
            throw SigningKeyError.ambiguousSource
        case (let file?, nil):
            try refuseInsideRepository(file, repositoryRoot: repositoryRoot)
            guard let data = try? Data(contentsOf: file) else { throw SigningKeyError.unreadable(path: file.path) }
            encoded = String(decoding: data, as: UTF8.self)
        case (nil, let value?):
            encoded = value
        }
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: trimmed),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw SigningKeyError.malformed
        }
        return key
    }

    static func refuseInsideRepository(_ file: URL, repositoryRoot: URL) throws {
        let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        if path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            throw SigningKeyError.insideRepository(path: file.path)
        }
    }
}

enum SigningKeyGenerator {
    /// Writes a new private key readable only by its owner, and returns its public key, which is
    /// safe to print and to pin in the app.
    static func generate(to file: URL, repositoryRoot: URL) throws -> Curve25519.Signing.PublicKey {
        try SigningKeySource.refuseInsideRepository(file, repositoryRoot: repositoryRoot)
        let key = Curve25519.Signing.PrivateKey()
        let contents = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
        // O_EXCL: never replaces an existing key, even one created between a check and the write.
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { throw SigningKeyError.alreadyExists(path: file.path) }
            throw SigningKeyError.unreadable(path: file.path)
        }
        defer { close(fd) }
        let written = contents.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == contents.count, fsync(fd) == 0 else {
            unlink(file.path)
            throw SigningKeyError.unreadable(path: file.path)
        }
        return key.publicKey
    }
}
