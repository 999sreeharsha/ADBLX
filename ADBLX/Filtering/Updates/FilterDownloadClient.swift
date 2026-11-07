import Foundation
import OSLog

struct DownloadedFilter: Equatable {
    var filterID: String
    var tempFileURL: URL
    var expectedChecksum: String
    var version: String
}

enum FilterDownloadClientError: Error, Equatable {
    case unexpectedStatusCode(Int)
    case invalidResponse
    /// Over `FilterDownloadClient.maxListBytes`; nothing of it is kept.
    case tooLarge(filterID: String)
}

/// Downloads one filter's body to a temp file. Does not verify checksums or install —
/// purely fetch-and-locate-on-disk, so callers can verify before touching any App Group
/// state (see UpdateCoordinator's data flow in the Sprint 2 design doc).
actor FilterDownloadClient {
    /// About four times the largest list (EasyList, 2.06 MB, 2026-11-07), and well inside the
    /// compile budget. Revisit when any list passes 4 MB: a list over the cap needs an app release.
    /// The Publisher refuses lists over the same figure (`Validator.maxListBytes`).
    nonisolated static let maxListBytes = 8 * 1_024 * 1_024

    private let session: HTTPSession
    private let maxListBytes: Int
    private static let logger = Logger(subsystem: "com.ADBLX", category: "FilterDownloadClient")

    /// Dedicated subdirectory under the system temp directory — no other component
    /// writes here. Transactional scratch space only; never a source of truth (Sprint
    /// 8.0 Commit 4's storage-class boundary — see the design spec's glossary).
    nonisolated static let workspaceDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.ADBLX.ADBLX.Downloads", isDirectory: true)

    init(session: HTTPSession, maxListBytes: Int = FilterDownloadClient.maxListBytes) {
        self.session = session
        self.maxListBytes = maxListBytes
    }

    /// Streams the list straight into the workspace, never holding it in memory, and stops as
    /// soon as it passes `maxListBytes` (SEC-09).
    func download(_ entry: FilterManifest.Entry) async throws -> DownloadedFilter {
        try FileManager.default.createDirectory(
            at: Self.workspaceDirectory, withIntermediateDirectories: true
        )
        let tempURL = Self.workspaceDirectory
            .appendingPathComponent("\(entry.id)-\(UUID().uuidString).tmp")

        let response: URLResponse
        do {
            response = try await session.download(for: URLRequest(url: entry.sourceURL), maxBytes: maxListBytes, to: tempURL)
        } catch HTTPSessionError.tooLarge {
            Self.logger.notice("list download refused reason=tooLarge capBytes=\(self.maxListBytes, privacy: .public)")
            throw FilterDownloadClientError.tooLarge(filterID: entry.id)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw FilterDownloadClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw FilterDownloadClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

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
