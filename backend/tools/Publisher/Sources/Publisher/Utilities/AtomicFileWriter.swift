import Foundation

enum AtomicFileWriterError: Error, Equatable {
    case fsyncFailed(errno: Int32)
    case renameFailed(description: String)
}

/// Mirrors ADBLX/Filtering/Storage/AtomicRuleWriter.swift's pattern (that type lives in the
/// iOS app target and can't be imported here): write to a temp file in the same directory,
/// fsync, rename over the destination. Guarantees a reader never observes a partially
/// written manifest.json or FilterRegistry.md.
struct AtomicFileWriter {
    func write(_ data: Data, to destinationURL: URL) throws {
        let directory = destinationURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")

        try data.write(to: tempURL, options: .atomic)

        let fd = open(tempURL.path, O_WRONLY)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw AtomicFileWriterError.fsyncFailed(errno: errno)
        }
        let syncResult = fcntl(fd, F_FULLFSYNC)
        // Capture errno immediately — a successful close(fd) can reset errno to 0 (or another
        // unrelated value), overwriting the real fsync failure's errno if read afterward.
        let syncErrno = errno
        close(fd)
        if syncResult != 0 {
            try? FileManager.default.removeItem(at: tempURL)
            throw AtomicFileWriterError.fsyncFailed(errno: syncErrno)
        }

        do {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            // `replaceItemAt` throws a Swift `Error` (typically `CocoaError`/`NSError`), not a
            // raw errno — capture its description rather than an unrelated stale `errno` value.
            throw AtomicFileWriterError.renameFailed(description: String(describing: error))
        }
    }
}
