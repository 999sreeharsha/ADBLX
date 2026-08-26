import Foundation

/// Basic sanity validation before a filter source enters the compile stage.
/// Guards against empty, truncated, or non-UTF8 filter source payloads.
///
/// Target: main app ONLY. `validate` is `nonisolated`.
struct FilterValidator {
    enum ValidationError: Error, Equatable {
        case notUTF8
        case empty
        case tooLarge(byteCount: Int, limit: Int)
    }

    /// Generous ceiling — this is a sanity guard against corrupt/truncated downloads,
    /// not a tight budget. The real rule-count budget (150K/extension) is enforced later,
    /// in the partitioning stage, against parsed rule counts.
    var maxByteCount: Int = 50 * 1024 * 1024

    nonisolated func validate(_ data: Data) throws {
        guard !data.isEmpty else {
            throw ValidationError.empty
        }
        guard data.count <= maxByteCount else {
            throw ValidationError.tooLarge(byteCount: data.count, limit: maxByteCount)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ValidationError.notUTF8
        }
    }
}
