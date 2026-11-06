import CryptoKit
import Foundation
@testable import ADBLX

/// Serves test manifests the way the site does: signed, with the signature at
/// `signatures/<sha256>.sig` beside the manifest. The test key is passed to the verifier as
/// `trustedKeys`, so nothing depends on the build configuration or `ManifestTrust`'s lists.
nonisolated enum SignedManifests {
    static let key = P256.Signing.PrivateKey()
    /// A valid `manifestVersion`, later than `verifier`'s default minimum.
    static let version = "2026-11-07T00:00:00Z"

    /// Trusts `key` and the endpoint's own directory as the only allowed base.
    static func verifier(for endpoint: URL, minimum: Date = .distantPast) -> ManifestVerifier {
        ManifestVerifier(trustedKeys: [key.publicKey], allowedBases: [endpoint.deletingLastPathComponent()], builtInMinimum: minimum)
    }

    /// Serves exactly what `session` holds, signatures included.
    static func client(session: HTTPSession, endpoint: URL) -> ManifestClient {
        ManifestClient(session: session, endpoint: endpoint, verifier: verifier(for: endpoint))
    }

    /// For suites about what happens after a manifest is accepted: `session` serves the
    /// manifest, and its signature is made on request with `key`, like a site that signed it.
    static func signingClient(session: HTTPSession, endpoint: URL) -> ManifestClient {
        client(session: SigningSession(session), endpoint: endpoint)
    }

    /// The layout the verifier requires: `<manifest directory>/filters/<group>/<id>.txt`.
    static func sourceURL(_ endpoint: URL, group: FilterGroup, id: String) -> URL {
        endpoint.deletingLastPathComponent().appendingPathComponent("filters/\(group.rawValue)/\(id).txt")
    }

    static func signatureURL(for data: Data, at endpoint: URL) -> URL {
        endpoint.deletingLastPathComponent().appendingPathComponent("signatures/\(Checksum.sha256Hex(of: data)).sig")
    }

    static func signatureFile(_ data: Data, key: P256.Signing.PrivateKey = key) -> Data {
        Data((try! key.signature(for: data).rawRepresentation.base64EncodedString() + "\n").utf8)
    }

    /// The manifest's 200 response and its signature's, ready to merge into a `MockHTTPSession`.
    static func responses(
        _ manifest: FilterManifest, at endpoint: URL, headers: [String: String]? = nil
    ) -> [URL: Result<(Data, URLResponse), Error>] {
        responses(rawManifest: try! JSONEncoder().encode(manifest), at: endpoint, headers: headers)
    }

    static func responses(
        rawManifest data: Data, at endpoint: URL, headers: [String: String]? = nil, signedBy key: P256.Signing.PrivateKey = key
    ) -> [URL: Result<(Data, URLResponse), Error>] {
        let signatureURL = signatureURL(for: data, at: endpoint)
        return [
            endpoint: .success((data, HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: headers)!)),
            signatureURL: .success((
                signatureFile(data, key: key),
                HTTPURLResponse(url: signatureURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            ))
        ]
    }
}

/// Answers `signatures/<sha256>.sig` with a signature over the body it served with that
/// hash (404 if none), and everything else from the wrapped session.
final class SigningSession: @unchecked Sendable {
    private let wrapped: HTTPSession
    private let lock = NSLock()
    private var served: [String: Data] = [:]

    init(_ wrapped: HTTPSession) {
        self.wrapped = wrapped
    }
}

extension SigningSession: HTTPSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        if url.pathExtension == "sig", url.deletingLastPathComponent().lastPathComponent == "signatures" {
            let hash = url.deletingPathExtension().lastPathComponent
            guard let body = lock.withLock({ served[hash] }) else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            return (SignedManifests.signatureFile(body), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let (data, response) = try await wrapped.data(for: request)
        lock.withLock { served[Checksum.sha256Hex(of: data)] = data }
        return (data, response)
    }
}
