import Foundation

/// Thin seam over `URLSession.data(for:)` so `ManifestClient`/`FilterDownloadClient`
/// can be unit-tested with canned responses — no real network, no `URLProtocol` stubbing.
protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    /// Throws `HTTPSessionError.tooLarge` for a body over `maxBytes`.
    func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse)
}

enum HTTPSessionError: Error, Equatable {
    case tooLarge
}

extension HTTPSession {
    /// For test sessions, which hold the whole body anyway: checks the declared length, then
    /// the received byte count.
    func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse) {
        let (data, response) = try await data(for: request)
        guard response.expectedContentLength <= maxBytes, data.count <= maxBytes else { throw HTTPSessionError.tooLarge }
        return (data, response)
    }
}

extension URLSession: HTTPSession {
    /// Stops reading as soon as the declared length or the bytes received pass `maxBytes`, so an
    /// oversized body is never held in memory. Byte by byte, so only for small bodies.
    func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await bytes(for: request)
        guard response.expectedContentLength <= maxBytes else {
            bytes.task.cancel()
            throw HTTPSessionError.tooLarge
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                bytes.task.cancel()
                throw HTTPSessionError.tooLarge
            }
        }
        return (data, response)
    }
}

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
