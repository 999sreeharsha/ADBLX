import Testing
import Foundation
@testable import ADBLX

@Suite("FilterDownloadClient")
struct FilterDownloadClientTests {
    private func sampleEntry() -> FilterManifest.Entry {
        FilterManifest.Entry(
            id: "easylist", name: "EasyList", group: .ads,
            sourceURL: URL(string: "https://example.com/easylist.txt")!,
            version: "2026-07-18", checksumSHA256: "abc123", ruleCount: 100,
            enabledByDefault: true, premium: false
        )
    }

    @Test("successful download writes the response body to a temp file and returns matching metadata")
    func successfulDownloadWritesTempFile() async throws {
        let entry = sampleEntry()
        let body = Data("[\"rule-a\", \"rule-b\"]".utf8)
        let response = HTTPURLResponse(url: entry.sourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [entry.sourceURL: .success((body, response))])
        let client = FilterDownloadClient(session: session)

        let downloaded = try await client.download(entry)

        #expect(downloaded.filterID == "easylist")
        #expect(downloaded.expectedChecksum == "abc123")
        #expect(downloaded.version == "2026-07-18")
        #expect(try Data(contentsOf: downloaded.tempFileURL) == body)

        try? FileManager.default.removeItem(at: downloaded.tempFileURL)
    }

    @Test("non-2xx status throws FilterDownloadClientError.unexpectedStatusCode")
    func non2xxThrows() async {
        let entry = sampleEntry()
        let response = HTTPURLResponse(url: entry.sourceURL, statusCode: 404, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [entry.sourceURL: .success((Data(), response))])
        let client = FilterDownloadClient(session: session)

        await #expect(throws: FilterDownloadClientError.unexpectedStatusCode(404)) {
            _ = try await client.download(entry)
        }
    }

    @Test("network error propagates")
    func networkErrorPropagates() async {
        let entry = sampleEntry()
        let session = MockHTTPSession(responses: [entry.sourceURL: .failure(URLError(.notConnectedToInternet))])
        let client = FilterDownloadClient(session: session)

        await #expect(throws: URLError.self) {
            _ = try await client.download(entry)
        }
    }
}
