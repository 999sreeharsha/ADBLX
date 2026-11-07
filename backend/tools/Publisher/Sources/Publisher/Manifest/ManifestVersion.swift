import Foundation

enum ManifestVersionError: Error, Equatable, CustomStringConvertible {
    case required
    case malformed(String)
    case notLater(requested: String, committed: String)

    var description: String {
        switch self {
        case .required:
            return "The manifest changed. Pass --manifest-version with the current UTC time, e.g. 2026-11-06T09:30:00Z."
        case .malformed(let value):
            return "\(value) isn't a UTC timestamp in the form YYYY-MM-DDTHH:MM:SSZ."
        case .notLater(let requested, let committed):
            return "\(requested) isn't later than the committed manifest's version, \(committed)."
        }
    }
}

/// `manifestVersion` is a UTC timestamp, `YYYY-MM-DDTHH:MM:SSZ`. Fixed width, so string order is
/// time order. It is an input to `publish`, never the clock, so the output stays deterministic.
enum ManifestVersion {
    /// Unchanged entries keep the committed version, so publishing the same inputs again gives
    /// byte-identical output. Changed entries need a version later than the committed one: the
    /// app's rollback rule rejects anything not newer than what it has. A committed date-only
    /// version (the old format) counts as that day at 00:00:00Z and is never kept.
    static func resolve(entries: [ManifestEntry], requested: String?, previous: Manifest?) throws -> String {
        if let requested, !isTimestamp(requested) { throw ManifestVersionError.malformed(requested) }
        if let previous, previous.entries == entries, isTimestamp(previous.manifestVersion) {
            return previous.manifestVersion
        }
        guard let requested else { throw ManifestVersionError.required }
        if let previous, let committed = comparable(previous.manifestVersion), requested <= committed {
            throw ManifestVersionError.notLater(requested: requested, committed: previous.manifestVersion)
        }
        return requested
    }

    static func isTimestamp(_ value: String) -> Bool {
        guard value.utf8.count == 20,
              value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil else {
            return false
        }
        // The pattern alone allows 2026-02-30 and 24:00:00; a round trip through a real date doesn't.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    /// A committed version in the form `resolve` compares against.
    private static func comparable(_ committed: String) -> String? {
        if isTimestamp(committed) { return committed }
        if committed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return committed + "T00:00:00Z" }
        return nil
    }
}
