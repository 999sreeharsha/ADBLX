import CryptoKit
import Foundation

/// A P-256 key that signs manifests: an ordinary key file (K2, the recovery key) or a key inside
/// this Mac's Secure Enclave (K1). Both give the same signatures and the same public key type.
protocol ManifestSigningKey {
    var publicKey: P256.Signing.PublicKey { get }
    /// The 64-byte raw (r ‖ s) ECDSA signature.
    func manifestSignature(for data: Data) throws -> Data
}

extension P256.Signing.PrivateKey: ManifestSigningKey {
    func manifestSignature(for data: Data) throws -> Data { try signature(for: data).rawRepresentation }
}

extension SecureEnclave.P256.Signing.PrivateKey: ManifestSigningKey {
    /// Asks for the owner's password or Touch ID when the key was made by `keygen`.
    func manifestSignature(for data: Data) throws -> Data { try signature(for: data).rawRepresentation }
}

/// P-256 ECDSA signatures over the exact bytes of `manifest.json`, in `signatures/<sha256>.sig`:
/// the base64 of the 64-byte raw signature and a newline. The app verifies those same bytes
/// against its pinned public keys before parsing them. See `docs/Security/ManifestTrust.md`.
///
/// ECDSA signatures are randomized, so the signature file differs between runs even though the
/// manifest does not. Every one of them verifies.
enum ManifestSigning {
    /// Named after the manifest's SHA-256, so a cached signature can only belong to the manifest
    /// whose bytes the app hashed. The manifest and signature are cached separately.
    static func signatureFilename(for manifest: Data) -> String {
        SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined() + ".sig"
    }

    static func signatureFile(for manifest: Data, key: any ManifestSigningKey) throws -> Data {
        Data((try key.manifestSignature(for: manifest).base64EncodedString() + "\n").utf8)
    }

    /// True when any trusted key verifies the signature. Two are pinned during a rotation.
    static func verify(manifest: Data, signatureFile: Data, trustedKeys: [P256.Signing.PublicKey]) -> Bool {
        let text = String(decoding: signatureFile, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text), raw.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return trustedKeys.contains { $0.isValidSignature(signature, for: manifest) }
    }
}

/// Writing and signing the files the Pages deploy serves.
enum ManifestPublication {
    /// How long a superseded signature stays published. A device whose CDN edge still serves an
    /// older manifest needs its signature for minutes or hours; every day it stays, that old
    /// manifest can be replayed to a fresh install.
    static let signatureRetention: TimeInterval = 7 * 86_400

    /// Signs the manifest as it is on disk, the bytes devices will download, and returns where the
    /// signature went. Signatures written more than `signatureRetention` ago are deleted, and so
    /// is any without a date in `signatures/index.json`: a file's own date in a fresh checkout is
    /// the checkout time.
    @discardableResult
    static func sign(
        manifestAt manifestURL: URL, key: any ManifestSigningKey, signaturesDirectory: URL, now: Date = Date()
    ) throws -> URL {
        let manifest = try Data(contentsOf: manifestURL)
        try FileManager.default.createDirectory(at: signaturesDirectory, withIntermediateDirectories: true)
        let filename = ManifestSigning.signatureFilename(for: manifest)
        let signatureURL = signaturesDirectory.appendingPathComponent(filename)
        try AtomicFileWriter().write(try ManifestSigning.signatureFile(for: manifest, key: key), to: signatureURL)

        let indexURL = signaturesDirectory.appendingPathComponent(SignatureIndex.filename)
        var signedAt = (try? SignatureIndex.read(from: indexURL)) ?? [:]
        signedAt[filename] = now
        signedAt = signedAt.filter { now.timeIntervalSince($0.value) <= signatureRetention || $0.key == filename }
        for name in try FileManager.default.contentsOfDirectory(atPath: signaturesDirectory.path)
        where name.hasSuffix(".sig") && signedAt[name] == nil {
            try FileManager.default.removeItem(at: signaturesDirectory.appendingPathComponent(name))
        }
        try AtomicFileWriter().write(try SignatureIndex.encode(signedAt), to: indexURL)
        return signatureURL
    }
}

/// `signatures/index.json`: when each published signature was written, as UTC seconds-precision
/// ISO 8601, keys sorted so identical inputs give identical bytes. The app never reads it.
enum SignatureIndex {
    static let filename = "index.json"

    static func read(from url: URL) throws -> [String: Date] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: Date].self, from: Data(contentsOf: url))
    }

    static func encode(_ signedAt: [String: Date]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(signedAt)
        data.append(0x0A)
        return data
    }
}

/// Errors carry no key material: CI shows thrown errors in its logs.
enum SigningKeyError: Error, Equatable, CustomStringConvertible {
    case missing
    case ambiguousSource
    case malformed
    case secureEnclaveUnavailable
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
            return "The signing key isn't a base64 P-256 private key or a Secure Enclave key this Mac can use. An enclave key made on another Mac, or before this Mac's enclave was reset, can't be used: sign with the recovery key (docs/Security/ManifestTrust.md)."
        case .secureEnclaveUnavailable:
            return "This Mac has no Secure Enclave."
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

    /// A key file holds the base64 of either a 32-byte P-256 private key or a Secure Enclave key's
    /// `dataRepresentation`, which only the enclave that made it can use.
    static func load(keyFile: URL?, environment: [String: String], repositoryRoot: URL) throws -> any ManifestSigningKey {
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
        guard let raw = Data(base64Encoded: trimmed) else { throw SigningKeyError.malformed }
        if raw.count == 32 {
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) else { throw SigningKeyError.malformed }
            return key
        }
        guard SecureEnclave.isAvailable else { throw SigningKeyError.secureEnclaveUnavailable }
        // Garbage and another Mac's enclave key fail the same way here.
        guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: raw) else {
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
    /// Writes a new key readable only by its owner, and returns its public key, which is safe to
    /// print and to pin in the app.
    ///
    /// With `secureEnclave`, the key is made inside this Mac's Secure Enclave and can never leave
    /// it: the file holds only a handle that this enclave alone can use. Every signature asks for
    /// user presence (Touch ID, or the login password on a Mac without it). Not biometrics only:
    /// such a key is lost for good when the enrolled fingerprints change.
    static func generate(to file: URL, repositoryRoot: URL, secureEnclave: Bool) throws -> P256.Signing.PublicKey {
        try SigningKeySource.refuseInsideRepository(file, repositoryRoot: repositoryRoot)
        let publicKey: P256.Signing.PublicKey
        let keyData: Data
        if secureEnclave {
            guard SecureEnclave.isAvailable else { throw SigningKeyError.secureEnclaveUnavailable }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error
            ) else { throw SigningKeyError.secureEnclaveUnavailable }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            (publicKey, keyData) = (key.publicKey, key.dataRepresentation)
        } else {
            let key = P256.Signing.PrivateKey()
            (publicKey, keyData) = (key.publicKey, key.rawRepresentation)
        }
        let contents = Data((keyData.base64EncodedString() + "\n").utf8)
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
        return publicKey
    }
}
