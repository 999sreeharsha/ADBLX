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
    // Optional artificial delay before returning, in nanoseconds — additive, defaults
    // to 0 so every existing call site is unaffected. Lets tests force genuinely
    // overlapping concurrent requests (e.g. 3+ concurrent UpdateCoordinator.run()
    // callers) instead of relying on incidental async-let scheduling, which can't
    // reliably prove a fix for a race that only manifests under staggered completion.
    private var delayNanoseconds: UInt64

    init(responses: [URL: Result<(Data, URLResponse), Error>], delayNanoseconds: UInt64 = 0) {
        self.responses = responses
        self.delayNanoseconds = delayNanoseconds
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let result = responses[url] else {
            throw UnregisteredURL(url: request.url ?? URL(string: "about:blank")!)
        }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try result.get()
    }
}
