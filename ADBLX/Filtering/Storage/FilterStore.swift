import Foundation

/// Sole owner of the App Group filesystem layout:
///
///   Filters/     — raw/normalized filter list source data
///   Compiled/    — partitioned, compiled JSON ready for each Content Blocker extension
///   Metadata/    — installed_filters.json, manifest.json, statistics.json
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

    /// Non-atomic convenience write for metadata-sized files (small, low update frequency).
    /// Compiled rule JSON MUST go through AtomicRuleWriter instead — this method is not
    /// safe for anything a Content Blocker extension will load.
    func writeMetadata(_ data: Data, filename: String) throws {
        let fileURL = try url(for: .metadata).appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
    }

    func directoryURL(_ directory: Directory) throws -> URL {
        try url(for: directory)
    }
}

enum FilterStoreError: Error {
    case appGroupContainerUnavailable
}
