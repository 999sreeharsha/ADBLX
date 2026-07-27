import Foundation

enum AtomicFileWriterError: Error, Equatable {
    case fsyncFailed(errno: Int32)
    case renameFailed(errno: Int32)
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
        close(fd)
        if syncResult != 0 {
            try? FileManager.default.removeItem(at: tempURL)
            throw AtomicFileWriterError.fsyncFailed(errno: errno)
        }

        do {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw AtomicFileWriterError.renameFailed(errno: errno)
        }
    }
}
