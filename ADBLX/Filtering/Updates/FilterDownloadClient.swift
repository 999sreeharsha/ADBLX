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

    /// Dedicated subdirectory under the system temp directory — no other component
    /// writes here. Transactional scratch space only; never a source of truth (Sprint
    /// 8.0 Commit 4's storage-class boundary — see the design spec's glossary).
    nonisolated static let workspaceDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.ADBLX.ADBLX.Downloads", isDirectory: true)

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

        try FileManager.default.createDirectory(
            at: Self.workspaceDirectory, withIntermediateDirectories: true
        )
        let tempURL = Self.workspaceDirectory
            .appendingPathComponent("\(entry.id)-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)

        return DownloadedFilter(
            filterID: entry.id,
            tempFileURL: tempURL,
            expectedChecksum: entry.checksumSHA256,
            version: entry.version
        )
    }

    /// Empties the entire workspace directory, regardless of its contents — self-healing
    /// against a prior crash that skipped cleanup, per Sprint 8.0 Commit 4. Called once
    /// per transaction, after commit or rollback has completely settled, never per-file.
    nonisolated func cleanupWorkspace() throws {
        guard FileManager.default.fileExists(atPath: Self.workspaceDirectory.path) else { return }
        let contents = try FileManager.default.contentsOfDirectory(
            at: Self.workspaceDirectory, includingPropertiesForKeys: nil
        )
        for url in contents {
            try FileManager.default.removeItem(at: url)
        }
    }
}
