import Foundation

enum ManifestFetchResult: Equatable {
    case notModified
    case updated(FilterManifest, etag: String?)
}

enum ManifestClientError: Error, Equatable {
    case unexpectedStatusCode(Int)
    case invalidResponse
}

/// Fetches `manifest.json` from a configurable endpoint, honoring ETag/If-None-Match.
actor ManifestClient {
    private let session: HTTPSession
    private let endpoint: URL

    init(session: HTTPSession, endpoint: URL) {
        self.session = session
        self.endpoint = endpoint
    }

    func fetch(previousETag: String?) async throws -> ManifestFetchResult {
        var request = URLRequest(url: endpoint)
        if let previousETag {
            request.setValue(previousETag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManifestClientError.invalidResponse
        }

        if httpResponse.statusCode == 304 {
            return .notModified
        }
        guard httpResponse.statusCode == 200 else {
            throw ManifestClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let manifest = try JSONDecoder().decode(FilterManifest.self, from: data)
        let etag = httpResponse.value(forHTTPHeaderField: "ETag")
        return .updated(manifest, etag: etag)
    }
}
