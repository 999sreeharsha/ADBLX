import CryptoKit
import XCTest
@testable import Publisher

final class SigningTests: XCTestCase {
    private let manifest = ManifestJSONWriter.write(Manifest(
        manifestVersion: "2026-11-06",
        entries: [
            ManifestEntry(
                id: "easylist", name: "EasyList", group: "ads",
                sourceURL: "https://cdn.adblx.com/filters/ads/easylist.txt",
                version: "2026-11-06", checksumSHA256: String(repeating: "a", count: 64), ruleCount: 2,
                enabledByDefault: true, premium: false
            )
        ]
    ))

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Signing

    func test_signatureVerifiesAgainstThePublicKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try ManifestSigning.signatureFile(for: manifest, key: key)

        XCTAssertTrue(ManifestSigning.verify(manifest: manifest, signatureFile: signature, trustedKeys: [key.publicKey]))
    }

    func test_changingAnyManifestByteFailsVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try ManifestSigning.signatureFile(for: manifest, key: key)

        for index in manifest.indices {
            var tampered = manifest
            tampered[index] ^= 0x01
            XCTAssertFalse(
                ManifestSigning.verify(manifest: tampered, signatureFile: signature, trustedKeys: [key.publicKey]),
                "flipping byte \(index) still verified"
            )
        }
    }

    func test_changingAnySignatureByteFailsVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let raw = try XCTUnwrap(Data(base64Encoded: String(decoding: try ManifestSigning.signatureFile(for: manifest, key: key), as: UTF8.self).trimmingCharacters(in: .newlines)))

        for index in raw.indices {
            var tampered = raw
            tampered[index] ^= 0x01
            let file = Data((tampered.base64EncodedString() + "\n").utf8)
            XCTAssertFalse(
                ManifestSigning.verify(manifest: manifest, signatureFile: file, trustedKeys: [key.publicKey]),
                "flipping signature byte \(index) still verified"
            )
        }
    }

    func test_aKeyThatIsNotPinnedFailsVerification() throws {
        let signature = try ManifestSigning.signatureFile(for: manifest, key: Curve25519.Signing.PrivateKey())

        XCTAssertFalse(ManifestSigning.verify(
            manifest: manifest, signatureFile: signature, trustedKeys: [Curve25519.Signing.PrivateKey().publicKey]
        ))
    }

    // Rotation: the app pins the current key and the next one, so either verifies.
    func test_eitherPinnedKeyVerifies() throws {
        let current = Curve25519.Signing.PrivateKey()
        let next = Curve25519.Signing.PrivateKey()
        let pinned = [current.publicKey, next.publicKey]

        for key in [current, next] {
            let signature = try ManifestSigning.signatureFile(for: manifest, key: key)
            XCTAssertTrue(ManifestSigning.verify(manifest: manifest, signatureFile: signature, trustedKeys: pinned))
        }
    }

    func test_aMalformedSignatureFileFailsVerification() {
        let key = Curve25519.Signing.PrivateKey()
        for file in ["", "not base64!\n", Data(count: 64).base64EncodedString()] {
            XCTAssertFalse(ManifestSigning.verify(manifest: manifest, signatureFile: Data(file.utf8), trustedKeys: [key.publicKey]))
        }
    }

    // CryptoKit's Ed25519 signatures are randomized, so the signature file differs between runs.
    // What must not differ is the signed manifest, and every run's signature must verify.
    func test_manifestStaysByteIdenticalAndEveryRunsSignatureVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let signatures = directory.appendingPathComponent("signatures", isDirectory: true)

        var manifests: [Data] = []
        for _ in 0..<3 {
            try AtomicFileWriter().write(manifest, to: manifestURL)
            let signatureURL = try ManifestPublication.sign(manifestAt: manifestURL, key: key, signaturesDirectory: signatures)
            let written = try Data(contentsOf: manifestURL)
            manifests.append(written)
            XCTAssertTrue(ManifestSigning.verify(
                manifest: written, signatureFile: try Data(contentsOf: signatureURL), trustedKeys: [key.publicKey]
            ))
        }
        XCTAssertEqual(Set(manifests).count, 1)
        XCTAssertEqual(manifests.first, manifest)
    }

    // The app fetches the signature named by the hash of the bytes it downloaded, so a CDN copy
    // of a signature can never belong to a different manifest.
    func test_theSignatureIsNamedAfterTheManifestsHash() throws {
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try manifest.write(to: manifestURL)

        let signatureURL = try ManifestPublication.sign(
            manifestAt: manifestURL, key: Curve25519.Signing.PrivateKey(),
            signaturesDirectory: directory.appendingPathComponent("signatures", isDirectory: true)
        )

        let hash = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(signatureURL.lastPathComponent, "\(hash).sig")
        XCTAssertEqual(signatureURL.deletingLastPathComponent().lastPathComponent, "signatures")
        XCTAssertTrue(FileManager.default.fileExists(atPath: signatureURL.path))
    }

    // A device whose CDN edge still serves the previous manifest must still find its signature.
    func test_signingANewManifestKeepsTheEarlierSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let signatures = directory.appendingPathComponent("signatures", isDirectory: true)
        var newer = manifest
        newer.append(contentsOf: Data(" ".utf8))

        try manifest.write(to: manifestURL)
        let first = try ManifestPublication.sign(manifestAt: manifestURL, key: key, signaturesDirectory: signatures)
        try newer.write(to: manifestURL)
        let second = try ManifestPublication.sign(manifestAt: manifestURL, key: key, signaturesDirectory: signatures)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(ManifestSigning.verify(manifest: manifest, signatureFile: try Data(contentsOf: first), trustedKeys: [key.publicKey]))
        XCTAssertTrue(ManifestSigning.verify(manifest: newer, signatureFile: try Data(contentsOf: second), trustedKeys: [key.publicKey]))
    }

    // MARK: - Keys

    func test_keyLoadsFromTheEnvironment() throws {
        let key = Curve25519.Signing.PrivateKey()
        let loaded = try SigningKeySource.load(
            keyFile: nil,
            environment: [SigningKeySource.environmentVariable: key.rawRepresentation.base64EncodedString()],
            repositoryRoot: try temporaryDirectory()
        )

        XCTAssertEqual(loaded.publicKey.rawRepresentation, key.publicKey.rawRepresentation)
    }

    func test_keyLoadsFromAFileOutsideTheRepository() throws {
        let key = Curve25519.Signing.PrivateKey()
        let file = try temporaryDirectory().appendingPathComponent("manifest-signing.key")
        try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: file)

        let loaded = try SigningKeySource.load(keyFile: file, environment: [:], repositoryRoot: try temporaryDirectory())

        XCTAssertEqual(loaded.publicKey.rawRepresentation, key.publicKey.rawRepresentation)
    }

    func test_givingBothAFileAndTheEnvironmentIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        let file = try temporaryDirectory().appendingPathComponent("manifest-signing.key")
        try Data(key.utf8).write(to: file)

        XCTAssertThrowsError(try SigningKeySource.load(
            keyFile: file, environment: [SigningKeySource.environmentVariable: key], repositoryRoot: try temporaryDirectory()
        )) { XCTAssertEqual($0 as? SigningKeyError, .ambiguousSource) }
    }

    func test_noKeyIsAnError() throws {
        XCTAssertThrowsError(try SigningKeySource.load(keyFile: nil, environment: [:], repositoryRoot: try temporaryDirectory())) {
            XCTAssertEqual($0 as? SigningKeyError, .missing)
        }
    }

    func test_aKeyFileInsideTheRepositoryIsRefused() throws {
        let repository = try temporaryDirectory()
        let file = repository.appendingPathComponent("backend/manifest-signing.key")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString().utf8).write(to: file)

        XCTAssertThrowsError(try SigningKeySource.load(keyFile: file, environment: [:], repositoryRoot: repository)) {
            guard case .insideRepository = $0 as? SigningKeyError else { return XCTFail("got \($0)") }
        }
    }

    // CI logs show thrown errors, so none may echo what it was given.
    func test_aMalformedKeyIsRefusedWithoutEchoingIt() throws {
        let secretLooking = "c2VjcmV0LWtleS1tYXRlcmlhbC10aGF0LWlzLXdyb25n"
        XCTAssertThrowsError(try SigningKeySource.load(
            keyFile: nil, environment: [SigningKeySource.environmentVariable: secretLooking], repositoryRoot: try temporaryDirectory()
        )) { error in
            XCTAssertEqual(error as? SigningKeyError, .malformed)
            XCTAssertFalse(String(describing: error).contains(secretLooking))
            XCTAssertFalse(error.localizedDescription.contains(secretLooking))
        }
    }

    func test_keygenWritesAnOwnerOnlyKeyThatLoads() throws {
        let file = try temporaryDirectory().appendingPathComponent("manifest-signing.key")

        let publicKey = try SigningKeyGenerator.generate(to: file, repositoryRoot: try temporaryDirectory())

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let loaded = try SigningKeySource.load(keyFile: file, environment: [:], repositoryRoot: try temporaryDirectory())
        XCTAssertEqual(loaded.publicKey.rawRepresentation, publicKey.rawRepresentation)
    }

    func test_keygenNeverOverwritesAKey() throws {
        let file = try temporaryDirectory().appendingPathComponent("manifest-signing.key")
        try Data("existing".utf8).write(to: file)

        XCTAssertThrowsError(try SigningKeyGenerator.generate(to: file, repositoryRoot: try temporaryDirectory())) {
            guard case .alreadyExists = $0 as? SigningKeyError else { return XCTFail("got \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("existing".utf8))
    }

    func test_keygenRefusesAPathInsideTheRepository() throws {
        let repository = try temporaryDirectory()

        XCTAssertThrowsError(try SigningKeyGenerator.generate(
            to: repository.appendingPathComponent("manifest-signing.key"), repositoryRoot: repository
        )) {
            guard case .insideRepository = $0 as? SigningKeyError else { return XCTFail("got \($0)") }
        }
    }
}
