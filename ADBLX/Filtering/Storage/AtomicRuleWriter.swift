// ADBLX/Filtering/Storage/AtomicRuleWriter.swift
import Foundation

/// Durability seam for AtomicRuleWriter. Production uses RealFilesystem; tests inject a
/// FailingFilesystem that throws at a chosen step, proving FR-05's guarantee (old file stays
/// intact and loadable on any failure) without needing to crash the process mid-write.
protocol AtomicFilesystem: Sendable {
    func write(_ data: Data, to url: URL) throws
    func fsync(atPath path: String) throws
    func replace(_ destination: URL, with tempURL: URL) throws
}

struct RealFilesystem: AtomicFilesystem {
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// Raw POSIX `open` + `F_FULLFSYNC` (full device flush, not just the weaker default
    /// `fsync` buffering guarantee); always closes the fd, including on the throw path.
    func fsync(atPath path: String) throws {
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else {
            throw AtomicRuleWriter.WriteError.fsyncFailed(errno: errno)
        }
        defer { close(fd) }

        let result = fcntl(fd, F_FULLFSYNC)
        if result != 0 {
            throw AtomicRuleWriter.WriteError.fsyncFailed(errno: errno)
        }
    }

    func replace(_ destination: URL, with tempURL: URL) throws {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
    }
}

/// Writes compiled rule JSON so that a reader (a Content Blocker extension, or this app on
/// next launch) never observes a partial or corrupted file — even across a crash or power
/// loss mid-write.
///
/// Sequence: write to a temp file in the same directory → fsync → rename over the target.
/// `rename(2)` is atomic on APFS for same-volume moves, so the reader either sees the old
/// file or the fully-written new one, never something in between.
///
/// Maps to FR-05 (atomic write; rollback to last-good on failure).
/// Target: main app ONLY. `write` is `nonisolated` — see Task 3's note on
/// SWIFT_DEFAULT_ACTOR_ISOLATION.
struct AtomicRuleWriter {
    enum WriteError: Error, Equatable {
        case fsyncFailed(errno: Int32)
        case renameFailed(errno: Int32)
    }

    private let filesystem: AtomicFilesystem

    init(filesystem: AtomicFilesystem = RealFilesystem()) {
        self.filesystem = filesystem
    }

    /// Writes `data` to `destinationURL`, replacing any existing file atomically.
    /// On failure, the destination file is left untouched (old contents still readable) —
    /// callers should treat a thrown error as "keep last-good rules," per FR-05.
    nonisolated func write(_ data: Data, to destinationURL: URL) throws {
        let directory = destinationURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")

        try filesystem.write(data, to: tempURL)

        do {
            try filesystem.fsync(atPath: tempURL.path)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        do {
            try filesystem.replace(destinationURL, with: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw WriteError.renameFailed(errno: errno)
        }
    }
}
