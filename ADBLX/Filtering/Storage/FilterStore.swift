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
    private let overrideBaseURL: URL?
    private let swapPaths: @Sendable (URL, URL) throws -> Void

    init(
        appGroupIdentifier: String = AppGroup.identifier,
        fileManager: FileManager = .default,
        overrideBaseURL: URL? = nil,
        swapPaths: @escaping @Sendable (URL, URL) throws -> Void = { try FilterStore.swapPathsAtomically($0, $1) }
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fileManager = fileManager
        self.overrideBaseURL = overrideBaseURL
        self.swapPaths = swapPaths
    }

    /// Exchanges two paths in one call (`renamex_np` with `RENAME_SWAP`, APFS), so a crash leaves
    /// both as they were or both swapped. A plain rename can't replace a non-empty directory, and
    /// moving one aside first would leave a window with neither in place.
    nonisolated static func swapPathsAtomically(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// A rename is atomic but only durable once its directory reaches the disk, so a power loss
    /// soon after a swap could otherwise bring back the old entries. `F_FULLFSYNC`, as
    /// `AtomicRuleWriter` uses for files.
    nonisolated static func flushDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Root container URL for the App Group. Not exposed outside this type —
    /// callers ask for files/data, not paths.
    private func containerURL() throws -> URL {
        if let overrideBaseURL {
            return overrideBaseURL
        }
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

    /// Deletes a metadata file. Absent already is not an error.
    func removeMetadata(filename: String) throws {
        let fileURL = try url(for: .metadata).appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
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

    /// A compiled file's size from its file metadata, without reading it. `nil` if it's absent.
    func compiledFileSize(_ filename: String) -> Int? {
        guard let path = try? url(for: .compiled).appendingPathComponent(filename).path,
              let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    func directoryURL(_ directory: Directory) throws -> URL {
        try url(for: directory)
    }

    /// Copies the current `Compiled/`, `Metadata/`, and `Filters/` directories into a `Previous/`
    /// root, replacing any leftover snapshot from an earlier run. Call before any write
    /// in an update batch begins; pair with `restore(_:)` on failure.
    func snapshotForRollback() throws -> RollbackSnapshot {
        try discardRollbackSnapshot()
        let previousRoot = try previousRootURL()
        try fileManager.createDirectory(at: previousRoot, withIntermediateDirectories: true)

        let compiledSnapshot = previousRoot.appendingPathComponent("Compiled", isDirectory: true)
        let metadataSnapshot = previousRoot.appendingPathComponent("Metadata", isDirectory: true)
        let filtersSnapshot = previousRoot.appendingPathComponent("Filters", isDirectory: true)

        do {
            try copyDirectoryContents(from: try url(for: .compiled), to: compiledSnapshot)
            try copyDirectoryContents(from: try url(for: .metadata), to: metadataSnapshot)
            try copyDirectoryContents(from: try url(for: .filters), to: filtersSnapshot)
        } catch {
            // Most likely a full disk, which a partial copy would only make worse.
            try? fileManager.removeItem(at: previousRoot)
            throw error
        }

        return RollbackSnapshot(
            compiledSnapshotDir: compiledSnapshot,
            metadataSnapshotDir: metadataSnapshot,
            filtersSnapshotDir: filtersSnapshot
        )
    }

    /// Replaces the entire current contents of `Compiled/`, `Metadata/`, and `Filters/` with the
    /// snapshot's contents (files present only in the current state and absent from the
    /// snapshot are removed), then discards the `Previous/` root.
    /// Each directory is swapped in by one atomic rename, so a crash leaves it either as it was or
    /// fully restored, never half-copied, and a full disk can't stop it. A crash between two swaps
    /// can still leave the directories from different points; reconcile handles that.
    ///
    /// A restore that stops after a swap spends the snapshot: the swapped directories' newer
    /// contents are now in `Previous/`, and restoring it again would put them back. `Previous/` is
    /// renamed to `Previous.spent/` (a rename needs no space), and a later restore of it throws
    /// `snapshotSpent`. One that fails on the first swap has changed nothing and stays usable.
    func restore(_ snapshot: RollbackSnapshot) throws {
        let saved = [snapshot.compiledSnapshotDir, snapshot.metadataSnapshotDir, snapshot.filtersSnapshotDir]
        guard saved.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            throw FilterStoreError.snapshotSpent
        }
        let live = [try url(for: .compiled), try url(for: .metadata), try url(for: .filters)]
        let container = try containerURL()
        let previousRoot = try previousRootURL()

        for (index, pair) in zip(saved, live).enumerated() {
            do {
                try swapIntoPlace(pair.0, at: pair.1)
            } catch {
                if index > 0 { spend(previousRoot) }
                try? Self.flushDirectory(container)
                throw error
            }
        }
        // The swaps have happened either way; failing here would report a rollback that worked
        // as one that didn't.
        try? Self.flushDirectory(container)
        try? fileManager.removeItem(at: previousRoot)
    }

    /// Discards any leftover snapshot in the `Previous/` directory. Called after a batch
    /// update commits successfully to ensure no transient snapshot data leaks on disk.
    func discardRollbackSnapshot() throws {
        for root in [try previousRootURL(), try spentRootURL()] where fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }

    private func spend(_ previousRoot: URL) {
        guard let spent = try? spentRootURL() else { return }
        try? fileManager.removeItem(at: spent)
        if (try? fileManager.moveItem(at: previousRoot, to: spent)) == nil {
            // Deleting also makes a second restore refuse it; it is only slower and can stop part-way.
            try? fileManager.removeItem(at: previousRoot)
        }
    }

    /// The live directory's old contents end up at `saved`, inside `Previous/`, which `restore`
    /// then deletes.
    private func swapIntoPlace(_ saved: URL, at live: URL) throws {
        try swapPaths(saved, live)
    }

    private func previousRootURL() throws -> URL {
        try containerURL().appendingPathComponent("Previous", isDirectory: true)
    }

    private func spentRootURL() throws -> URL {
        try containerURL().appendingPathComponent("Previous.spent", isDirectory: true)
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
}

/// Opaque to callers outside this file — a copy of `Compiled/`, `Metadata/`, and `Filters/` taken by
/// `snapshotForRollback()`, consumed by `restore(_:)`.
struct RollbackSnapshot {
    fileprivate let compiledSnapshotDir: URL
    fileprivate let metadataSnapshotDir: URL
    fileprivate let filtersSnapshotDir: URL
}

nonisolated enum FilterStoreError: Error {
    case appGroupContainerUnavailable
    case snapshotSpent
}
