import Foundation

/// Thin seam over `URLSession.data(for:)` so `ManifestClient`/`FilterDownloadClient`
/// can be unit-tested with canned responses — no real network, no `URLProtocol` stubbing.
protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}

/// Test/debug helper: returns a canned `Result` keyed by exact request URL.
/// Lives in the main target (not the test target) so it's reusable across every
/// `Updates/` test suite via `@testable import ADBLX`, matching how production types
/// in this module are structured.
final class MockHTTPSession: HTTPSession, @unchecked Sendable {
    struct UnregisteredURL: Error {
        var url: URL
    }

    private var responses: [URL: Result<(Data, URLResponse), Error>]

    init(responses: [URL: Result<(Data, URLResponse), Error>]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let result = responses[url] else {
            throw UnregisteredURL(url: request.url ?? URL(string: "about:blank")!)
        }
        return try result.get()
    }
}
