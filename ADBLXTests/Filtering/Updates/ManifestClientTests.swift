// ADBLXTests/Filtering/Updates/ManifestClientTests.swift
import CryptoKit
import Testing
import Foundation
@testable import ADBLX

@Suite("ManifestClient")
struct ManifestClientTests {
    private let endpoint = URL(string: "https://example.com/adblx/manifest.json")!

    private func sampleManifest(_ version: String = SignedManifests.version) -> FilterManifest {
        let entry = FilterManifest.Entry(
            id: "easylist", name: "EasyList", group: .ads,
            sourceURL: SignedManifests.sourceURL(endpoint, group: .ads, id: "easylist"),
            version: "2026-07-18", checksumSHA256: "abc123", ruleCount: 100,
            enabledByDefault: true, premium: false
        )
        return FilterManifest(manifestVersion: version, entries: [entry])
    }

    private func response(_ url: URL, _ status: Int, _ headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private func expectRejected(
        _ reason: ManifestRejection, _ client: ManifestClient, cached: FilterManifest? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await #expect(throws: reason, sourceLocation: sourceLocation) {
            _ = try await client.fetch(previousETag: nil, cached: cached)
        }
    }

    @Test("A signed 200 returns .updated with the decoded manifest and ETag")
    func signed200IsUpdated() async throws {
        let session = MockHTTPSession(responses: SignedManifests.responses(sampleManifest(), at: endpoint, headers: ["ETag": "\"v1\""]))
        let client = SignedManifests.client(session: session, endpoint: endpoint)

        let result = try await client.fetch(previousETag: nil, cached: nil)

        #expect(result == .updated(sampleManifest(), etag: "\"v1\""))
    }

    @Test("The signature is fetched from signatures/<sha256 of the downloaded bytes>.sig beside the manifest")
    func signatureURLComesFromTheDownloadedBytes() async throws {
        let data = try JSONEncoder().encode(sampleManifest())
        let session = RecordingSession(MockHTTPSession(responses: SignedManifests.responses(rawManifest: data, at: endpoint)))
        let client = SignedManifests.client(session: session, endpoint: endpoint)

        _ = try await client.fetch(previousETag: nil, cached: nil)

        let expected = URL(string: "https://example.com/adblx/signatures/\(Checksum.sha256Hex(of: data)).sig")!
        #expect(session.requestedURLs == [endpoint, expected])
    }

    @Test("A 304 returns .notModified and fetches no signature")
    func notModifiedFetchesNoSignature() async throws {
        let session = RecordingSession(MockHTTPSession(responses: [endpoint: .success((Data(), response(endpoint, 304)))]))
        let client = SignedManifests.client(session: session, endpoint: endpoint)

        let result = try await client.fetch(previousETag: "\"v1\"", cached: sampleManifest())

        #expect(result == .notModified)
        #expect(session.requestedURLs == [endpoint])
    }

    @Test("The request includes If-None-Match when a previous ETag is supplied")
    func includesIfNoneMatchHeader() async throws {
        let session = RecordingSession(MockHTTPSession(responses: [endpoint: .success((Data(), response(endpoint, 304)))]))
        let client = SignedManifests.client(session: session, endpoint: endpoint)

        _ = try await client.fetch(previousETag: "\"cached-etag\"", cached: nil)

        #expect(session.requests.first?.value(forHTTPHeaderField: "If-None-Match") == "\"cached-etag\"")
    }

    // An old signature: the file at this manifest's hash holds a signature over other bytes.
    @Test("A signature over other bytes is rejected")
    func mismatchedSignatureIsRejected() async throws {
        let data = try JSONEncoder().encode(sampleManifest())
        let older = try JSONEncoder().encode(sampleManifest("2026-11-06T00:00:00Z"))
        let signatureURL = SignedManifests.signatureURL(for: data, at: endpoint)
        let session = MockHTTPSession(responses: [
            endpoint: .success((data, response(endpoint, 200))),
            signatureURL: .success((SignedManifests.signatureFile(older), response(signatureURL, 200)))
        ])

        await expectRejected(.signature, SignedManifests.client(session: session, endpoint: endpoint))
    }

    @Test("A manifest signed by a key that isn't trusted is rejected")
    func untrustedKeyIsRejected() async throws {
        let data = try JSONEncoder().encode(sampleManifest())
        let session = MockHTTPSession(responses: SignedManifests.responses(rawManifest: data, at: endpoint, signedBy: P256.Signing.PrivateKey()))

        await expectRejected(.signature, SignedManifests.client(session: session, endpoint: endpoint))
    }

    @Test("A missing signature, or one that can't be fetched, is rejected")
    func missingSignatureIsRejected() async throws {
        let data = try JSONEncoder().encode(sampleManifest())
        let signatureURL = SignedManifests.signatureURL(for: data, at: endpoint)

        for signature: Result<(Data, URLResponse), Error> in [
            .success((Data("not found".utf8), response(signatureURL, 404))),
            .failure(URLError(.timedOut))
        ] {
            let session = MockHTTPSession(responses: [endpoint: .success((data, response(endpoint, 200))), signatureURL: signature])
            await expectRejected(.signature, SignedManifests.client(session: session, endpoint: endpoint))
        }
    }

    @Test("A signature file over 1 KB is rejected")
    func oversizedSignatureIsRejected() async throws {
        let data = try JSONEncoder().encode(sampleManifest())
        let signatureURL = SignedManifests.signatureURL(for: data, at: endpoint)
        let padded = SignedManifests.signatureFile(data) + Data(repeating: 0x0A, count: 1_024)
        let session = MockHTTPSession(responses: [
            endpoint: .success((data, response(endpoint, 200))),
            signatureURL: .success((padded, response(signatureURL, 200)))
        ])

        await expectRejected(.signature, SignedManifests.client(session: session, endpoint: endpoint))
    }

    @Test("A manifest whose Content-Length is over 256 KB is refused without fetching its signature")
    func oversizedContentLengthIsRefused() async throws {
        let data = try JSONEncoder().encode(sampleManifest())
        var responses = SignedManifests.responses(rawManifest: data, at: endpoint)
        responses[endpoint] = .success((data, response(endpoint, 200, ["Content-Length": "\(256 * 1_024 + 1)"])))
        let session = RecordingSession(MockHTTPSession(responses: responses))

        await expectRejected(.size, SignedManifests.client(session: session, endpoint: endpoint))
        #expect(session.requestedURLs == [endpoint])
    }

    @Test("A manifest body over 256 KB is refused when no length is sent")
    func oversizedBodyIsRefused() async throws {
        let data = Data(repeating: 0x20, count: 256 * 1_024 + 1)
        let session = MockHTTPSession(responses: SignedManifests.responses(rawManifest: data, at: endpoint))

        await expectRejected(.size, SignedManifests.client(session: session, endpoint: endpoint))
    }

    @Test("Signed bytes that aren't a manifest are rejected as malformed")
    func signedMalformedIsRejected() async {
        let session = MockHTTPSession(responses: SignedManifests.responses(rawManifest: Data("not json".utf8), at: endpoint))

        await expectRejected(.malformed, SignedManifests.client(session: session, endpoint: endpoint))
    }

    @Test("Unsigned junk is rejected on its signature before anything parses it")
    func unsignedJunkIsRejectedOnItsSignature() async {
        let session = MockHTTPSession(responses: [endpoint: .success((Data("not json".utf8), response(endpoint, 200)))])

        await expectRejected(.signature, SignedManifests.client(session: session, endpoint: endpoint))
    }

    @Test("The same version and content as the cached manifest returns .unchanged with the new ETag")
    func sameAsCachedIsUnchanged() async throws {
        let session = MockHTTPSession(responses: SignedManifests.responses(sampleManifest(), at: endpoint, headers: ["ETag": "\"v2\""]))
        let client = SignedManifests.client(session: session, endpoint: endpoint)

        #expect(try await client.fetch(previousETag: nil, cached: sampleManifest()) == .unchanged(etag: "\"v2\""))
    }

    @Test("The verifier's rules apply: a manifest older than the cached one is rejected")
    func olderThanCachedIsRejected() async throws {
        let session = MockHTTPSession(responses: SignedManifests.responses(sampleManifest("2026-11-06T00:00:00Z"), at: endpoint))

        await expectRejected(.rollback, SignedManifests.client(session: session, endpoint: endpoint), cached: sampleManifest())
    }

    @Test("404 throws ManifestClientError.unexpectedStatusCode")
    func returns404Throws() async {
        let session = MockHTTPSession(responses: [endpoint: .success((Data(), response(endpoint, 404)))])
        let client = SignedManifests.client(session: session, endpoint: endpoint)

        await #expect(throws: ManifestClientError.unexpectedStatusCode(404)) {
            _ = try await client.fetch(previousETag: nil, cached: nil)
        }
    }

    @Test("500 throws ManifestClientError.unexpectedStatusCode")
    func returns500Throws() async {
        let session = MockHTTPSession(responses: [endpoint: .success((Data(), response(endpoint, 500)))])
        let client = SignedManifests.client(session: session, endpoint: endpoint)

        await #expect(throws: ManifestClientError.unexpectedStatusCode(500)) {
            _ = try await client.fetch(previousETag: nil, cached: nil)
        }
    }

    @Test("A network error fetching the manifest propagates")
    func networkErrorPropagates() async {
        let session = MockHTTPSession(responses: [endpoint: .failure(URLError(.timedOut))])
        let client = SignedManifests.client(session: session, endpoint: endpoint)

        await #expect(throws: URLError.self) {
            _ = try await client.fetch(previousETag: nil, cached: nil)
        }
    }
}

/// Records each request, then answers from the wrapped session.
private final class RecordingSession: @unchecked Sendable {
    private let wrapped: MockHTTPSession
    private(set) var requests: [URLRequest] = []
    var requestedURLs: [URL] { requests.compactMap(\.url) }

    init(_ wrapped: MockHTTPSession) {
        self.wrapped = wrapped
    }
}

extension RecordingSession: HTTPSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try await wrapped.data(for: request)
    }
}
