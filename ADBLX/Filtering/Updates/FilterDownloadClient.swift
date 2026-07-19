import Foundation

struct DownloadedFilter: Equatable {
    var filterID: String
    var tempFileURL: URL
    var expectedChecksum: String
    var version: String
}

enum FilterDownloadClientError: Error, Equatable {
    case unexpectedStatusCode(Int)
    case invalidResponse
}

/// Downloads one filter's body to a temp file. Does not verify checksums or install —
/// purely fetch-and-locate-on-disk, so callers can verify before touching any App Group
/// state (see UpdateCoordinator's data flow in the Sprint 2 design doc).
actor FilterDownloadClient {
    private let session: HTTPSession

    init(session: HTTPSession) {
        self.session = session
    }

    func download(_ entry: FilterManifest.Entry) async throws -> DownloadedFilter {
        let (data, response) = try await session.data(for: URLRequest(url: entry.sourceURL))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FilterDownloadClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw FilterDownloadClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(entry.id)-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)

        return DownloadedFilter(
            filterID: entry.id,
            tempFileURL: tempURL,
            expectedChecksum: entry.checksumSHA256,
            version: entry.version
        )
    }
}
