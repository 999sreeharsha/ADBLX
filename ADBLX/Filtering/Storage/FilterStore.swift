import Foundation

/// Sole owner of the App Group filesystem layout:
///
///   Filters/     — raw/normalized filter list source data
///   Compiled/    — partitioned, compiled JSON ready for each Content Blocker extension
///   Metadata/    — installed_filters.json, manifest.json, statistics.json
///   Previous/    — rollback snapshot (copies of the three above). Exists only while a
///                  transaction is open: `commit` renames it to `Previous.done/` as the
///                  transaction's last step, so one found at launch belongs to a transaction
///                  that died, and `recoverInterruptedTransaction` restores it.
///
/// See `docs/superpowers/plans/2026-11-07-background-updates.md`, "When a transaction counts as
/// finished".
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
    private let transactionHook: (@Sendable (TransactionStep) async -> Void)?

    /// `transactionHook` is for tests only: it lets one stop a transaction at a step, as a killed
    /// process would.
    init(
        appGroupIdentifier: String = AppGroup.identifier,
        fileManager: FileManager = .default,
        overrideBaseURL: URL? = nil,
        swapPaths: @escaping @Sendable (URL, URL) throws -> Void = { try FilterStore.swapPathsAtomically($0, $1) },
        transactionHook: (@Sendable (TransactionStep) async -> Void)? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fileManager = fileManager
        self.overrideBaseURL = overrideBaseURL
        self.swapPaths = swapPaths
        self.transactionHook = transactionHook
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

    /// Copies the current `Compiled/`, `Metadata/`, and `Filters/` directories into a new
    /// `Previous/`. Call under the transaction gate before any write in the transaction; end it
    /// with `commit(_:)`, or `restore(_:)` on failure.
    ///
    /// The copy goes into `Previous.partial/` and is renamed to `Previous/` only once whole, so a
    /// `Previous/` always holds a complete pre-transaction state. Each saved directory gets a
    /// marker named after the snapshot's id, which tells a restore cut short which directories it
    /// already swapped. A leftover `Previous/` from a rollback that stopped part-way is restored
    /// first rather than discarded: deleting it would leave that mixed state for good.
    func snapshotForRollback() throws -> RollbackSnapshot {
        try recoverInterruptedTransaction()
        let container = try containerURL()
        let partial = container.appendingPathComponent(SnapshotPaths.partial, isDirectory: true)
        let id = UUID().uuidString
        let names = SnapshotPaths.directories
        do {
            if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
            for (name, directory) in zip(names, [Directory.compiled, .metadata, .filters]) {
                let saved = partial.appendingPathComponent(name, isDirectory: true)
                try copyDirectoryContents(from: try url(for: directory), to: saved)
                try Data().write(to: saved.appendingPathComponent(SnapshotPaths.marker(id)))
            }
            try Data(id.utf8).write(to: partial.appendingPathComponent(SnapshotPaths.idFile))
            try fileManager.moveItem(at: partial, to: try previousRootURL())
        } catch {
            // Most likely a full disk, which a partial copy would only make worse.
            try? fileManager.removeItem(at: partial)
            throw error
        }
        // Before any live write, so a power loss can't keep the writes and lose the snapshot.
        try? Self.flushDirectory(container)
        return RollbackSnapshot(id: id)
    }

    /// The transaction's commit point and last step: one rename of `Previous/` to
    /// `Previous.done/`. If the rename fails the transaction did not commit, and the caller
    /// restores as for any other failure. Deleting `Previous.done/` afterwards is clean-up.
    func commit(_ snapshot: RollbackSnapshot) async throws {
        await transactionHook?(.beforeCommit)
        guard try snapshotID() == snapshot.id else { throw FilterStoreError.snapshotSpent }
        try retire(try previousRootURL())
        await transactionHook?(.afterCommit)
        try? fileManager.removeItem(at: try doneRootURL())
    }

    /// Replaces the entire current contents of `Compiled/`, `Metadata/`, and `Filters/` with the
    /// snapshot's contents (files present only in the current state and absent from the
    /// snapshot are removed), then retires `Previous/`.
    /// Each directory is swapped in by one atomic rename, so a crash leaves it either as it was or
    /// fully restored, never half-copied, and a full disk can't stop it.
    ///
    /// A restore that stops between swaps can be run again, in this run or at the next launch: a
    /// directory whose marker has moved to the live side was already swapped and is skipped.
    /// Retiring `Previous/` is the point the restore is finished; the markers left in the live
    /// directories are deleted after it, and a stray one carries an id no snapshot uses again.
    func restore(_ snapshot: RollbackSnapshot) throws {
        guard try snapshotID() == snapshot.id else { throw FilterStoreError.snapshotSpent }
        try restorePrevious(id: snapshot.id)
    }

    /// Run at launch, under the gate, before anything else touches the filter directories. No
    /// transaction can be open then (the gate is per process and the app is the only writer), so
    /// a `Previous/` belongs to one that died before committing, and is restored. Returns whether
    /// it restored one; the caller then has Safari reload every blocker, since the dead
    /// transaction may already have reloaded some with the rules just undone.
    @discardableResult
    func recoverInterruptedTransaction() throws -> Bool {
        let container = try containerURL()
        for name in [SnapshotPaths.partial, SnapshotPaths.done, SnapshotPaths.legacySpent] {
            let leftover = container.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: leftover.path) { try fileManager.removeItem(at: leftover) }
        }
        let previous = try previousRootURL()
        guard fileManager.fileExists(atPath: previous.path) else { return false }
        guard let id = try snapshotID() else {
            // Written before snapshots carried an id: no telling whether its copy finished.
            try fileManager.removeItem(at: previous)
            return false
        }
        try restorePrevious(id: id)
        return true
    }

    private func restorePrevious(id: String) throws {
        let previous = try previousRootURL()
        let container = try containerURL()
        let marker = SnapshotPaths.marker(id)
        let live = [try url(for: .compiled), try url(for: .metadata), try url(for: .filters)]
        for (name, liveDirectory) in zip(SnapshotPaths.directories, live) {
            let saved = previous.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: saved.appendingPathComponent(marker).path) {
                do {
                    try swapPaths(saved, liveDirectory)
                } catch {
                    try? Self.flushDirectory(container)
                    throw error
                }
            } else if !fileManager.fileExists(atPath: liveDirectory.appendingPathComponent(marker).path) {
                throw FilterStoreError.snapshotSpent
            }
        }
        try? Self.flushDirectory(container)
        // The swaps have happened; failing from here on would report a rollback that worked as
        // one that didn't.
        try? retire(previous)
        try? fileManager.removeItem(at: try doneRootURL())
        for liveDirectory in live {
            try? fileManager.removeItem(at: liveDirectory.appendingPathComponent(marker))
        }
    }

    /// Renames a finished snapshot out of the way in one step and flushes the rename.
    private func retire(_ previous: URL) throws {
        let done = try doneRootURL()
        if fileManager.fileExists(atPath: done.path) { try fileManager.removeItem(at: done) }
        try fileManager.moveItem(at: previous, to: done)
        try? Self.flushDirectory(try containerURL())
    }

    private func snapshotID() throws -> String? {
        let file = try previousRootURL().appendingPathComponent(SnapshotPaths.idFile)
        return (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func previousRootURL() throws -> URL {
        try containerURL().appendingPathComponent(SnapshotPaths.previous, isDirectory: true)
    }

    private func doneRootURL() throws -> URL {
        try containerURL().appendingPathComponent(SnapshotPaths.done, isDirectory: true)
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: source.path) else { return }
        for name in try fileManager.contentsOfDirectory(atPath: source.path) where !SnapshotPaths.isMarker(name) {
            try fileManager.copyItem(
                at: source.appendingPathComponent(name),
                to: destination.appendingPathComponent(name)
            )
        }
    }
}

/// Opaque to callers outside this file: the transaction's snapshot, taken by
/// `snapshotForRollback()` and ended by `commit(_:)` or `restore(_:)`.
struct RollbackSnapshot {
    fileprivate let id: String
}

/// Steps a test can stop a transaction at (`FilterStore`'s `transactionHook`).
nonisolated enum TransactionStep: Sendable {
    case beforeCommit
    case afterCommit
}

private nonisolated enum SnapshotPaths {
    static let previous = "Previous"
    static let partial = "Previous.partial"
    static let done = "Previous.done"
    /// Left by a restore that stopped part-way, before restores could resume.
    static let legacySpent = "Previous.spent"
    static let idFile = "snapshot-id"
    static let directories = ["Compiled", "Metadata", "Filters"]
    static func marker(_ id: String) -> String { ".snapshot-\(id)" }
    static func isMarker(_ name: String) -> Bool { name.hasPrefix(".snapshot-") }
}

nonisolated enum FilterStoreError: Error {
    case appGroupContainerUnavailable
    /// The snapshot was already committed or restored, or another replaced it.
    case snapshotSpent
}
