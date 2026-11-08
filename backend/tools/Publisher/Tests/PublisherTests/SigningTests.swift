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

    /// Keygen's enclave keys require user presence, and macOS refuses to create one while the
    /// screen is locked (`errSecInteractionNotAllowed`). That says nothing about the code, so the
    /// test skips. Seen on unattended runs (docs/gotchas.md).
    private func skippingWhenTheScreenIsLocked<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as NSError
            where error.domain == NSOSStatusErrorDomain && error.code == Int(errSecInteractionNotAllowed) {
            throw XCTSkip("The screen is locked, so macOS won't create a user-presence enclave key (-25308).")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Signing

    func test_signatureVerifiesAgainstThePublicKey() throws {
        let key = P256.Signing.PrivateKey()
        let signature = try ManifestSigning.signatureFile(for: manifest, key: key)

        XCTAssertTrue(ManifestSigning.verify(manifest: manifest, signatureFile: signature, trustedKeys: [key.publicKey]))
    }

    func test_changingAnyManifestByteFailsVerification() throws {
        let key = P256.Signing.PrivateKey()
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
        let key = P256.Signing.PrivateKey()
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
        let signature = try ManifestSigning.signatureFile(for: manifest, key: P256.Signing.PrivateKey())

        XCTAssertFalse(ManifestSigning.verify(
            manifest: manifest, signatureFile: signature, trustedKeys: [P256.Signing.PrivateKey().publicKey]
        ))
    }

    // Rotation: the app pins the current key and the next one, so either verifies.
    func test_eitherPinnedKeyVerifies() throws {
        let current = P256.Signing.PrivateKey()
        let next = P256.Signing.PrivateKey()
        let pinned = [current.publicKey, next.publicKey]

        for key in [current, next] {
            let signature = try ManifestSigning.signatureFile(for: manifest, key: key)
            XCTAssertTrue(ManifestSigning.verify(manifest: manifest, signatureFile: signature, trustedKeys: pinned))
        }
    }

    func test_aMalformedSignatureFileFailsVerification() {
        let key = P256.Signing.PrivateKey()
        for file in ["", "not base64!\n", Data(count: 64).base64EncodedString()] {
            XCTAssertFalse(ManifestSigning.verify(manifest: manifest, signatureFile: Data(file.utf8), trustedKeys: [key.publicKey]))
        }
    }

    // ECDSA signatures are randomized, so the signature file differs between runs.
    // What must not differ is the signed manifest, and every run's signature must verify.
    func test_manifestStaysByteIdenticalAndEveryRunsSignatureVerifies() throws {
        let key = P256.Signing.PrivateKey()
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
            manifestAt: manifestURL, key: P256.Signing.PrivateKey(),
            signaturesDirectory: directory.appendingPathComponent("signatures", isDirectory: true)
        )

        let hash = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(signatureURL.lastPathComponent, "\(hash).sig")
        XCTAssertEqual(signatureURL.deletingLastPathComponent().lastPathComponent, "signatures")
        XCTAssertTrue(FileManager.default.fileExists(atPath: signatureURL.path))
    }

    // A device whose CDN edge still serves the previous manifest must still find its signature.
    func test_signingANewManifestKeepsTheEarlierSignature() throws {
        let key = P256.Signing.PrivateKey()
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

    // Old signatures keep old manifests valid, and a fresh install has no cached version to
    // reject one with. A stale CDN edge lasts minutes or hours, so a week is plenty.
    func test_signingDeletesSignaturesOlderThanTheRetention() throws {
        let key = P256.Signing.PrivateKey()
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let signatures = directory.appendingPathComponent("signatures", isDirectory: true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func publish(_ bytes: Data, daysLater days: Double) throws -> URL {
            try bytes.write(to: manifestURL)
            return try ManifestPublication.sign(
                manifestAt: manifestURL, key: key, signaturesDirectory: signatures,
                now: start.addingTimeInterval(days * 86_400)
            )
        }

        let old = try publish(Data("old".utf8), daysLater: 0)
        let recent = try publish(Data("recent".utf8), daysLater: 2)
        let current = try publish(Data("current".utf8), daysLater: 8)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "8 days old, kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    // A file's date in a fresh checkout is the checkout time, so age comes from the index.
    func test_aSignatureWithNoRecordedDateIsDeleted() throws {
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let signatures = directory.appendingPathComponent("signatures", isDirectory: true)
        try FileManager.default.createDirectory(at: signatures, withIntermediateDirectories: true)
        let undated = signatures.appendingPathComponent(String(repeating: "0", count: 64) + ".sig")
        try Data("x\n".utf8).write(to: undated)
        try manifest.write(to: manifestURL)

        let current = try ManifestPublication.sign(manifestAt: manifestURL, key: P256.Signing.PrivateKey(), signaturesDirectory: signatures)

        XCTAssertFalse(FileManager.default.fileExists(atPath: undated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    // The index is committed and deployed, so it must not churn between identical runs.
    func test_theSignatureIndexIsStableForTheSameInputs() throws {
        let directory = try temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let signatures = directory.appendingPathComponent("signatures", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try manifest.write(to: manifestURL)

        var indexes: [Data] = []
        for _ in 0..<3 {
            try ManifestPublication.sign(manifestAt: manifestURL, key: P256.Signing.PrivateKey(), signaturesDirectory: signatures, now: now)
            indexes.append(try Data(contentsOf: signatures.appendingPathComponent("index.json")))
        }
        XCTAssertEqual(Set(indexes).count, 1)
    }

    // Recovery: K1 is tied to one Mac's Secure Enclave. When that Mac is gone, K2, an ordinary
    // key file, signs instead, and an app pinning both must accept it.
    func test_aManifestSignedWithTheRecoveryKeyFileVerifiesAgainstBothPinnedKeys() throws {
        let k1 = P256.Signing.PrivateKey()
        let k2File = try temporaryDirectory().appendingPathComponent("k2.key")
        let k2Public = try SigningKeyGenerator.generate(to: k2File, repositoryRoot: try temporaryDirectory(), secureEnclave: false)
        let k2 = try SigningKeySource.load(keyFile: k2File, environment: [:], repositoryRoot: try temporaryDirectory())

        let signature = try ManifestSigning.signatureFile(for: manifest, key: k2)

        XCTAssertTrue(ManifestSigning.verify(manifest: manifest, signatureFile: signature, trustedKeys: [k1.publicKey, k2Public]))
    }

    func test_aSecureEnclaveKeySignsManifestsThatVerify() throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave on this machine")
        // No access control, so the test needs no password; keygen's keys require user presence.
        let key = try SecureEnclave.P256.Signing.PrivateKey()

        let signature = try ManifestSigning.signatureFile(for: manifest, key: key)

        XCTAssertTrue(ManifestSigning.verify(manifest: manifest, signatureFile: signature, trustedKeys: [key.publicKey]))
    }

    func test_aLockedScreenSkipsInsteadOfFailing() {
        let locked = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))

        XCTAssertThrowsError(try skippingWhenTheScreenIsLocked { throw locked }) { error in
            XCTAssertTrue(error is XCTSkip, "got \(error)")
        }
    }

    func test_anyOtherKeychainErrorStillFails() {
        let other = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed))

        XCTAssertThrowsError(try skippingWhenTheScreenIsLocked { throw other }) { error in
            XCTAssertEqual(error as NSError, other)
        }
    }

    // Loading needs no password, only signing does, so this runs unattended.
    func test_keygenWithSecureEnclaveWritesAKeyThatLoadsAsTheSameEnclaveKey() throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "no Secure Enclave on this machine")
        let file = try temporaryDirectory().appendingPathComponent("k1.key")

        let publicKey = try skippingWhenTheScreenIsLocked {
            try SigningKeyGenerator.generate(to: file, repositoryRoot: try temporaryDirectory(), secureEnclave: true)
        }

        let loaded = try SigningKeySource.load(keyFile: file, environment: [:], repositoryRoot: try temporaryDirectory())
        XCTAssertTrue(loaded is SecureEnclave.P256.Signing.PrivateKey)
        XCTAssertEqual(loaded.publicKey.rawRepresentation, publicKey.rawRepresentation)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    // MARK: - Keys

    func test_keyLoadsFromTheEnvironment() throws {
        let key = P256.Signing.PrivateKey()
        let loaded = try SigningKeySource.load(
            keyFile: nil,
            environment: [SigningKeySource.environmentVariable: key.rawRepresentation.base64EncodedString()],
            repositoryRoot: try temporaryDirectory()
        )

        XCTAssertEqual(loaded.publicKey.rawRepresentation, key.publicKey.rawRepresentation)
    }

    func test_keyLoadsFromAFileOutsideTheRepository() throws {
        let key = P256.Signing.PrivateKey()
        let file = try temporaryDirectory().appendingPathComponent("manifest-signing.key")
        try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: file)

        let loaded = try SigningKeySource.load(keyFile: file, environment: [:], repositoryRoot: try temporaryDirectory())

        XCTAssertEqual(loaded.publicKey.rawRepresentation, key.publicKey.rawRepresentation)
    }

    func test_givingBothAFileAndTheEnvironmentIsRefused() throws {
        let key = P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
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
        try Data(P256.Signing.PrivateKey().rawRepresentation.base64EncodedString().utf8).write(to: file)

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

        let publicKey = try SigningKeyGenerator.generate(to: file, repositoryRoot: try temporaryDirectory(), secureEnclave: false)

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let loaded = try SigningKeySource.load(keyFile: file, environment: [:], repositoryRoot: try temporaryDirectory())
        XCTAssertEqual(loaded.publicKey.rawRepresentation, publicKey.rawRepresentation)
    }

    func test_keygenNeverOverwritesAKey() throws {
        let file = try temporaryDirectory().appendingPathComponent("manifest-signing.key")
        try Data("existing".utf8).write(to: file)

        XCTAssertThrowsError(try SigningKeyGenerator.generate(to: file, repositoryRoot: try temporaryDirectory(), secureEnclave: false)) {
            guard case .alreadyExists = $0 as? SigningKeyError else { return XCTFail("got \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("existing".utf8))
    }

    func test_keygenRefusesAPathInsideTheRepository() throws {
        let repository = try temporaryDirectory()

        XCTAssertThrowsError(try SigningKeyGenerator.generate(
            to: repository.appendingPathComponent("manifest-signing.key"), repositoryRoot: repository, secureEnclave: false
        )) {
            guard case .insideRepository = $0 as? SigningKeyError else { return XCTFail("got \($0)") }
        }
    }
}
