import Foundation

/// Sole owner of the App Group filesystem layout:
///
///   Filters/     — raw/normalized filter list source data
///   Compiled/    — partitioned, compiled JSON ready for each Content Blocker extension
///   Metadata/    — installed_filters.json, manifest.json, statistics.json
///   Previous/    — rollback snapshot root (Compiled/, Metadata/ copies); only exists
///                  transiently during an UpdateCoordinator batch (Sprint 2)
///
/// No other type in the app should call `FileManager` against the App Group container
/// directly. Route all reads/writes through this actor so there's one place that understands
/// the on-disk layout and one place to audit for the atomic-write guarantee (see
/// AtomicRuleWriter).
///
/// Target: main app ONLY. Extensions read the `Compiled/` directory via their own
/// (read-only, minimal) file access — they do not use this type.
actor FilterStore {
    enum Directory {
        case filters
        case compiled
        case metadata
    }

    private let appGroupIdentifier: String
    private let fileManager: FileManager

    init(appGroupIdentifier: String, fileManager: FileManager = .default) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fileManager = fileManager
    }

    /// Root container URL for the App Group. Not exposed outside this type —
    /// callers ask for files/data, not paths.
    private func containerURL() throws -> URL {
        guard let url = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw FilterStoreError.appGroupContainerUnavailable
        }
        return url
    }

    private func url(for directory: Directory) throws -> URL {
        let base = try containerURL()
        let subpath: String
        switch directory {
        case .filters: subpath = "Filters"
        case .compiled: subpath = "Compiled"
        case .metadata: subpath = "Metadata"
        }
        let dir = base.appendingPathComponent(subpath, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Reads raw data for a named file within a directory. Throws if absent —
    /// callers decide fallback/rollback behavior, this type doesn't guess.
    func read(_ filename: String, in directory: Directory) throws -> Data {
        let fileURL = try url(for: directory).appendingPathComponent(filename)
        return try Data(contentsOf: fileURL)
    }

    /// Atomic convenience write for metadata-sized files (small, low update frequency).
    /// Compiled rule JSON MUST go through AtomicRuleWriter instead — this method is not
    /// safe for anything a Content Blocker extension will load.
    /// The `.atomic` option is load-bearing: `RealHomeServiceTests.concurrentWriteNeverProducesTornRead`
    /// (Sprint 5A) depends on readers never observing a partial write — do not remove it.
    func writeMetadata(_ data: Data, filename: String) throws {
        let fileURL = try url(for: .metadata).appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Persists one filter's verified raw source payload to `Filters/<filterID>.json` —
    /// the canonical local cache `.remove` (Sprint 8.0 Commit 3) reads from to recompose
    /// a group without the network. Callers write this only after checksum verification.
    func writeFilterPayload(_ data: Data, filterID: String) throws {
        let fileURL = try url(for: .filters).appendingPathComponent("\(filterID).json")
        try data.write(to: fileURL, options: .atomic)
    }

    /// Reads a previously-persisted filter payload. Throws if absent — callers (e.g.
    /// `FilterPipeline.remove`) treat a missing payload as an error, not a silent skip,
    /// since `Filters/` is the only source of truth for recomposition.
    func readFilterPayload(filterID: String) throws -> Data {
        let fileURL = try url(for: .filters).appendingPathComponent("\(filterID).json")
        return try Data(contentsOf: fileURL)
    }

    /// Deletes a previously-persisted filter payload. Used by `FilterPipeline.remove` to
    /// clean up `Filters/<filterID>.json` once the group has been recomposed without it.
    func removeFilterPayload(filterID: String) throws {
        let fileURL = try url(for: .filters).appendingPathComponent("\(filterID).json")
        try fileManager.removeItem(at: fileURL)
    }

    func directoryURL(_ directory: Directory) throws -> URL {
        try url(for: directory)
    }

    /// Copies the current `Compiled/`, `Metadata/`, and `Filters/` directories into a `Previous/`
    /// root, replacing any leftover snapshot from an earlier run. Call before any write
    /// in an update batch begins; pair with `restore(_:)` on failure.
    func snapshotForRollback() throws -> RollbackSnapshot {
        let previousRoot = try previousRootURL()
        if fileManager.fileExists(atPath: previousRoot.path) {
            try fileManager.removeItem(at: previousRoot)
        }
        try fileManager.createDirectory(at: previousRoot, withIntermediateDirectories: true)

        let compiledSnapshot = previousRoot.appendingPathComponent("Compiled", isDirectory: true)
        let metadataSnapshot = previousRoot.appendingPathComponent("Metadata", isDirectory: true)
        let filtersSnapshot = previousRoot.appendingPathComponent("Filters", isDirectory: true)

        try copyDirectoryContents(from: try url(for: .compiled), to: compiledSnapshot)
        try copyDirectoryContents(from: try url(for: .metadata), to: metadataSnapshot)
        try copyDirectoryContents(from: try url(for: .filters), to: filtersSnapshot)

        return RollbackSnapshot(
            compiledSnapshotDir: compiledSnapshot,
            metadataSnapshotDir: metadataSnapshot,
            filtersSnapshotDir: filtersSnapshot
        )
    }

    /// Replaces the entire current contents of `Compiled/`, `Metadata/`, and `Filters/` with the
    /// snapshot's contents (files present only in the current state and absent from the
    /// snapshot are removed), then discards the `Previous/` root.
    func restore(_ snapshot: RollbackSnapshot) throws {
        try replaceDirectoryContents(at: try url(for: .compiled), with: snapshot.compiledSnapshotDir)
        try replaceDirectoryContents(at: try url(for: .metadata), with: snapshot.metadataSnapshotDir)
        try replaceDirectoryContents(at: try url(for: .filters), with: snapshot.filtersSnapshotDir)

        let previousRoot = try previousRootURL()
        try? fileManager.removeItem(at: previousRoot)
    }

    private func previousRootURL() throws -> URL {
        try containerURL().appendingPathComponent("Previous", isDirectory: true)
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: source.path) else { return }
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            try fileManager.copyItem(
                at: source.appendingPathComponent(name),
                to: destination.appendingPathComponent(name)
            )
        }
    }

    private func replaceDirectoryContents(at destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            try fileManager.copyItem(
                at: source.appendingPathComponent(name),
                to: destination.appendingPathComponent(name)
            )
        }
    }
}

/// Opaque to callers outside this file — a copy of `Compiled/`, `Metadata/`, and `Filters/` taken by
/// `snapshotForRollback()`, consumed by `restore(_:)`.
struct RollbackSnapshot {
    fileprivate let compiledSnapshotDir: URL
    fileprivate let metadataSnapshotDir: URL
    fileprivate let filtersSnapshotDir: URL
}

enum FilterStoreError: Error {
    case appGroupContainerUnavailable
}
