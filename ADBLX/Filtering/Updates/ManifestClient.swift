import Foundation

enum ManifestFetchResult: Equatable {
    case notModified
    /// A 200 whose manifest has the same version and content as the cached one: handled like a
    /// 304, but with the new ETag to save so the next check is a 304.
    case unchanged(etag: String?)
    case updated(FilterManifest, etag: String?)
}

enum ManifestClientError: Error, Equatable {
    case unexpectedStatusCode(Int)
    case invalidResponse
}

/// Fetches `manifest.json` from a configurable endpoint, honoring ETag/If-None-Match, and
/// returns it only once `ManifestVerifier` accepts it: the signature at
/// `signatures/<sha256>.sig` beside it, then every rule. A refused manifest throws
/// `ManifestRejection`. See docs/Security/ManifestTrust.md.
actor ManifestClient {
    /// Today's manifest is under 2 KB (ManifestTrust.md, Size).
    static let maxManifestBytes = 256 * 1_024
    static let maxSignatureBytes = 1_024

    private let session: HTTPSession
    private let endpoint: URL
    private let verifier: ManifestVerifier

    init(session: HTTPSession, endpoint: URL, verifier: ManifestVerifier) {
        self.session = session
        self.endpoint = endpoint
        self.verifier = verifier
    }

    /// `cached` is the last verified manifest, for the rollback rule.
    func fetch(previousETag: String?, cached: FilterManifest?) async throws -> ManifestFetchResult {
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let previousETag {
            request.setValue(previousETag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, maxBytes: Self.maxManifestBytes)
        } catch HTTPSessionError.tooLarge {
            throw ManifestRejection.size
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManifestClientError.invalidResponse
        }

        if httpResponse.statusCode == 304 {
            return .notModified
        }
        guard httpResponse.statusCode == 200 else {
            throw ManifestClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let signature = try await signatureFile(for: data)
        let etag = httpResponse.value(forHTTPHeaderField: "ETag")
        switch try verifier.verify(manifest: data, signatureFile: signature, from: endpoint, cached: cached) {
        case .accepted(let manifest):
            return .updated(manifest, etag: etag)
        case .unchanged:
            return .unchanged(etag: etag)
        }
    }

    /// Named after the exact bytes downloaded, so a CDN edge serving an older manifest is
    /// checked against that manifest's own signature. Any failure to get it is a rejection.
    private func signatureFile(for manifest: Data) async throws(ManifestRejection) -> Data {
        let url = endpoint.deletingLastPathComponent()
            .appendingPathComponent("signatures/\(Checksum.sha256Hex(of: manifest)).sig")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request, maxBytes: Self.maxSignatureBytes),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw .signature
        }
        return data
    }
}
