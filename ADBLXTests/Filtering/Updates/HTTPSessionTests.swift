// ADBLXTests/Filtering/Updates/HTTPSessionTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("HTTPSession")
struct HTTPSessionTests {
    @Test("MockHTTPSession returns the canned response for a matching URL")
    func mockReturnsCannedResponse() async throws {
        let url = URL(string: "https://example.com/manifest.json")!
        let responseData = Data("{\"key\":\"value\"}".utf8)
        let httpResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let mock = MockHTTPSession(responses: [url: .success((responseData, httpResponse))])

        let (data, response) = try await mock.data(for: URLRequest(url: url))

        #expect(data == responseData)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("MockHTTPSession throws the canned error for a matching URL")
    func mockThrowsCannedError() async {
        let url = URL(string: "https://example.com/manifest.json")!
        let mock = MockHTTPSession(responses: [url: .failure(URLError(.timedOut))])

        await #expect(throws: URLError.self) {
            _ = try await mock.data(for: URLRequest(url: url))
        }
    }

    @Test("MockHTTPSession throws for an unregistered URL")
    func mockThrowsForUnknownURL() async {
        let mock = MockHTTPSession(responses: [:])
        await #expect(throws: MockHTTPSession.UnregisteredURL.self) {
            _ = try await mock.data(for: URLRequest(url: URL(string: "https://example.com/other.json")!))
        }
    }
}
