import ArgumentParser
import CryptoKit
import Foundation

struct KeygenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keygen",
        abstract: "Create a manifest signing key outside the repository and print its public key."
    )

    @Option(name: .customLong("output"), help: "Where to write the private key. Must be outside the repository.")
    var output: String

    func run() throws {
        let publicKey = try SigningKeyGenerator.generate(
            to: URL(fileURLWithPath: output), repositoryRoot: PublisherPaths.repositoryRoot
        )
        print("✓ Wrote the private key to \(output) (owner read/write only)")
        print("  Store it offline; see docs/Security/ManifestTrust.md.")
        print("Public key (pin this in the app): \(publicKey.rawRepresentation.base64EncodedString())")
    }
}

struct SignCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign",
        abstract: "Sign backend/public/manifest.json, writing backend/public/signatures/<sha256>.sig."
    )

    @Option(name: .customLong("signing-key-file"), help: "Private key file, outside the repository. Or set \(SigningKeySource.environmentVariable).")
    var signingKeyFile: String?

    func run() throws {
        let key = try SigningKeySource.load(
            keyFile: signingKeyFile.map { URL(fileURLWithPath: $0) },
            environment: ProcessInfo.processInfo.environment,
            repositoryRoot: PublisherPaths.repositoryRoot
        )
        let signatureURL = try ManifestPublication.sign(
            manifestAt: PublisherPaths.manifestOutput, key: key, signaturesDirectory: PublisherPaths.signaturesOutput
        )
        print("✓ Wrote \(signatureURL.path)")
        print("  Signed with public key \(key.publicKey.rawRepresentation.base64EncodedString())")
    }
}

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check the manifest's signature against the public keys the app pins. Exits 1 if none verifies."
    )

    @Option(name: .customLong("public-key"), help: "A pinned public key (base64). Repeat for each.")
    var publicKeys: [String]

    func run() throws {
        let keys = try publicKeys.map { encoded -> Curve25519.Signing.PublicKey in
            guard let raw = Data(base64Encoded: encoded),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
                throw ArgumentParser.ValidationError("Not a base64 Ed25519 public key: \(encoded)")
            }
            return key
        }
        guard !keys.isEmpty else { throw ArgumentParser.ValidationError("Pass at least one --public-key.") }
        let manifest = try Data(contentsOf: PublisherPaths.manifestOutput)
        let signatureURL = PublisherPaths.signaturesOutput.appendingPathComponent(ManifestSigning.signatureFilename(for: manifest))
        guard let signature = try? Data(contentsOf: signatureURL),
              ManifestSigning.verify(manifest: manifest, signatureFile: signature, trustedKeys: keys) else {
            print("✗ \(signatureURL.path) is missing or doesn't verify")
            throw ExitCode(PublisherExitCode.validationFailure.rawValue)
        }
        print("✓ Signature verifies")
    }
}
