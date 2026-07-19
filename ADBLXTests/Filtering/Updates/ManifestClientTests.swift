// ADBLXTests/Filtering/Updates/ManifestClientTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("ManifestClient")
struct ManifestClientTests {
    private let endpoint = URL(string: "https://example.com/manifest.json")!

    private func sampleManifestJSON() -> Data {
        let entry = FilterManifest.Entry(
            id: "easylist", name: "EasyList", group: .ads, sourceURL: URL(string: "https://example.com/easylist.txt")!,
            version: "2026-07-18", checksumSHA256: "abc123", ruleCount: 100,
            enabledByDefault: true, premium: false
        )
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry])
        return try! JSONEncoder().encode(manifest)
    }

    @Test("200 with valid JSON returns .updated with the decoded manifest and ETag")
    func returns200AsUpdated() async throws {
        let responseData = sampleManifestJSON()
        let response = HTTPURLResponse(
            url: endpoint, statusCode: 200, httpVersion: nil,
            headerFields: ["ETag": "\"v1\""]
        )!
        let session = MockHTTPSession(responses: [endpoint: .success((responseData, response))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        let result = try await client.fetch(previousETag: nil)

        guard case .updated(let manifest, let etag) = result else {
            Issue.record("expected .updated")
            return
        }
        #expect(manifest.entries.first?.id == "easylist")
        #expect(etag == "\"v1\"")
    }

    @Test("304 returns .notModified")
    func returns304AsNotModified() async throws {
        let response = HTTPURLResponse(url: endpoint, statusCode: 304, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [endpoint: .success((Data(), response))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        let result = try await client.fetch(previousETag: "\"v1\"")

        #expect(result == .notModified)
    }

    @Test("request includes If-None-Match when a previous ETag is supplied")
    func includesIfNoneMatchHeader() async throws {
        final class CapturingSession: HTTPSession, @unchecked Sendable {
            var capturedRequest: URLRequest?
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                capturedRequest = request
                let response = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        }
        let session = CapturingSession()
        let client = ManifestClient(session: session, endpoint: endpoint)

        _ = try await client.fetch(previousETag: "\"cached-etag\"")

        #expect(session.capturedRequest?.value(forHTTPHeaderField: "If-None-Match") == "\"cached-etag\"")
    }

    @Test("404 throws ManifestClientError.unexpectedStatusCode")
    func returns404Throws() async {
        let response = HTTPURLResponse(url: endpoint, statusCode: 404, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [endpoint: .success((Data(), response))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        await #expect(throws: ManifestClientError.unexpectedStatusCode(404)) {
            _ = try await client.fetch(previousETag: nil)
        }
    }

    @Test("500 throws ManifestClientError.unexpectedStatusCode")
    func returns500Throws() async {
        let response = HTTPURLResponse(url: endpoint, statusCode: 500, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [endpoint: .success((Data(), response))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        await #expect(throws: ManifestClientError.unexpectedStatusCode(500)) {
            _ = try await client.fetch(previousETag: nil)
        }
    }

    @Test("malformed JSON body on a 200 throws a decoding error")
    func malformedJSONThrows() async {
        let response = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [endpoint: .success((Data("not json".utf8), response))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        await #expect(throws: (any Error).self) {
            _ = try await client.fetch(previousETag: nil)
        }
    }

    @Test("network error propagates")
    func networkErrorPropagates() async {
        let session = MockHTTPSession(responses: [endpoint: .failure(URLError(.timedOut))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        await #expect(throws: URLError.self) {
            _ = try await client.fetch(previousETag: nil)
        }
    }
}
