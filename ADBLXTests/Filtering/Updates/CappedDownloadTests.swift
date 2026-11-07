import Foundation
import Testing
@testable import ADBLX

/// `download(for:maxBytes:to:)` streams a list to disk and stops as soon as it passes the cap
/// (docs/superpowers/plans/2026-11-07-list-download-cap.md). The real-session tests use a stub
/// that sends the body in chunks and counts how many it sent, so a cap checked only at the end
/// fails them.
@Suite("Capped download", .serialized, .timeLimit(.minutes(1)))
struct CappedDownloadTests {
    private let url = URL(string: "https://lists.example/filters/ads/easylist.txt")!
    private static let chunk = 10_000

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedListStub.self]
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    /// An empty folder for the destination, so a refusal can be checked to leave nothing behind.
    private func destination() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("easylist.tmp")
    }

    private func expectNothingLeft(at destination: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let left = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(left.isEmpty, "left behind: \(left)", sourceLocation: sourceLocation)
    }

    private func serve(_ body: Data, declaredLength: Int?) {
        ChunkedListStub.configure(body: body, chunk: Self.chunk, declaredLength: declaredLength)
    }

    // MARK: Real URLSession

    @Test("A list under the cap arrives intact at the destination")
    func underTheCapArrives() async throws {
        let body = Data((0..<50_000).map { UInt8($0 % 251) })
        serve(body, declaredLength: body.count)
        let destination = try destination()

        let response = try await session().download(for: URLRequest(url: url), maxBytes: 100_000, to: destination)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test("A declared length over the cap is refused at the first chunk, leaving no file")
    func declaredOverTheCapIsRefused() async throws {
        serve(Data(repeating: 0x61, count: 200_000), declaredLength: 200_000)
        let destination = try destination()

        await #expect(throws: HTTPSessionError.tooLarge) {
            _ = try await session().download(for: URLRequest(url: url), maxBytes: 100_000, to: destination)
        }
        // The declared length stops it at the first chunk, give or take the few in flight; a
        // count-only check would run to about 13 chunks, a check at completion to all 20.
        #expect(ChunkedListStub.sentChunks <= 6)
        try expectNothingLeft(at: destination)
    }

    @Test("A body over the cap with no declared length is refused mid-download, leaving no file")
    func undeclaredOverTheCapIsRefused() async throws {
        serve(Data(repeating: 0x61, count: 200_000), declaredLength: nil)
        let destination = try destination()

        await #expect(throws: HTTPSessionError.tooLarge) {
            _ = try await session().download(for: URLRequest(url: url), maxBytes: 25_000, to: destination)
        }
        #expect(ChunkedListStub.sentChunks <= 10)
        try expectNothingLeft(at: destination)
    }

    @Test("A declared length that understates the body is refused once the bytes pass the cap")
    func understatedLengthIsRefused() async throws {
        serve(Data(repeating: 0x61, count: 200_000), declaredLength: 10_000)
        let destination = try destination()

        await #expect(throws: (any Error).self) {
            _ = try await session().download(for: URLRequest(url: url), maxBytes: 25_000, to: destination)
        }
        #expect(ChunkedListStub.sentChunks <= 10)
        try expectNothingLeft(at: destination)
    }

    @Test("A redirect to another host is not followed")
    func crossHostRedirectIsNotFollowed() async throws {
        ChunkedListStub.configure(body: Data("elsewhere".utf8), chunk: Self.chunk, declaredLength: nil,
                                  redirectTo: URL(string: "https://evil.example/filters/ads/easylist.txt")!)
        let destination = try destination()

        let response = try await session().download(for: URLRequest(url: url), maxBytes: 100_000, to: destination)

        #expect((response as? HTTPURLResponse)?.statusCode == 301)
        #expect(ChunkedListStub.requestedHosts == ["lists.example"])
        #expect(ChunkedListStub.sentChunks == 0)
    }

    // MARK: Test sessions (the protocol's default)

    @Test("A test session refuses a declared or received length over the cap, and writes what fits")
    func defaultImplementation() async throws {
        let small = Data(repeating: 0x62, count: 1_000)
        let big = Data(repeating: 0x62, count: 5_000)
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let lying = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "9000"])!

        for (body, response) in [(big, ok), (small, lying)] {
            let destination = try destination()
            await #expect(throws: HTTPSessionError.tooLarge) {
                _ = try await MockHTTPSession(responses: [url: .success((body, response))])
                    .download(for: URLRequest(url: url), maxBytes: 4_000, to: destination)
            }
            try expectNothingLeft(at: destination)
        }

        let destination = try destination()
        _ = try await MockHTTPSession(responses: [url: .success((small, ok))]).download(for: URLRequest(url: url), maxBytes: 4_000, to: destination)
        #expect(try Data(contentsOf: destination) == small)
    }
}

/// Sends a configured body in chunks, stopping when the loader cancels, and counts what it sent.
private final class ChunkedListStub: URLProtocol, @unchecked Sendable {
    private struct Config {
        var body = Data()
        var chunk = 10_000
        var declaredLength: Int?
        var redirectTo: URL?
        var sent = 0
        var hosts: [String] = []
        var generation = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var config = Config()
    private let stopped = NSLock()
    nonisolated(unsafe) private var isStopped = false

    static func configure(body: Data, chunk: Int, declaredLength: Int?, redirectTo: URL? = nil) {
        lock.withLock {
            let generation = config.generation + 1
            config = Config(body: body, chunk: chunk, declaredLength: declaredLength, redirectTo: redirectTo, generation: generation)
        }
    }

    static var sentChunks: Int { lock.withLock { config.sent } }
    static var requestedHosts: [String] { lock.withLock { config.hosts } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let config = Self.lock.withLock { Self.config }
        let url = request.url!
        Self.lock.withLock { Self.config.hosts.append(url.host() ?? "") }
        if let target = config.redirectTo, url.host() != target.host() {
            let response = HTTPURLResponse(url: url, statusCode: 301, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // As a server does: if the redirect isn't followed, the 3xx is the response.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let headers = config.declaredLength.map { ["Content-Length": "\($0)"] } ?? [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        // Off the loader thread, which must stay free to deliver stopLoading when the task is cancelled.
        Self.delivery.async { [self] in
            var offset = 0
            while offset < config.body.count, !stopped.withLock({ isStopped }) {
                let end = min(offset + config.chunk, config.body.count)
                client?.urlProtocol(self, didLoad: config.body.subdata(in: offset..<end))
                // A loop left over from an earlier test stops counting once the stub is reconfigured.
                Self.lock.withLock { if Self.config.generation == config.generation { Self.config.sent += 1 } }
                offset = end
                // Spaced so a cancel lands within two or three chunks of the cap.
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !stopped.withLock({ isStopped }) {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private static let delivery = DispatchQueue(label: "ChunkedListStub.delivery")

    override func stopLoading() {
        stopped.withLock { isStopped = true }
    }
}
