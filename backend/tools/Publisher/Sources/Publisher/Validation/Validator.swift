import Foundation

enum Validator {
    static let validGroups: Set<String> = ["ads", "privacy", "annoyances", "regional"]

    /// An id becomes a file name (`Filters/<id>.json`) and part of a URL on every device. The app
    /// rejects a manifest with any other id (docs/Security/ManifestTrust.md, Filter IDs).
    static let idPattern = "^[a-z0-9][a-z0-9-]{0,63}$"

    static func isValidID(_ id: String) -> Bool {
        id.range(of: idPattern, options: .regularExpression) != nil
    }

    /// Registry-level checks only. Pure function — no filesystem access.
    /// Accumulates every independent error found; does not stop at the first.
    static func validateRegistry(_ registry: Registry) -> [ValidationError] {
        var errors: [ValidationError] = []

        if registry.filters.isEmpty {
            errors.append(.emptyRegistry)
        }

        for entry in registry.filters where !isValidID(entry.id) {
            errors.append(.invalidID(id: entry.id))
        }

        for entry in registry.filters where !validGroups.contains(entry.group) {
            errors.append(.invalidGroup(id: entry.id, found: entry.group))
        }

        var seenIDs: Set<String> = []
        var duplicateIDs: Set<String> = []
        for entry in registry.filters {
            if seenIDs.contains(entry.id) {
                duplicateIDs.insert(entry.id)
            }
            seenIDs.insert(entry.id)
        }
        for id in duplicateIDs.sorted() {
            errors.append(.duplicateRegistryID(id: id))
        }

        return errors
    }

    /// Full validation entry point: registry-level checks, metadata cross-checks
    /// (missing/orphaned/duplicate/id-mismatch), and payload existence checks.
    /// Accumulates every error found; only throws for fatal filesystem errors
    /// (e.g. metadata directory itself unreadable).
    static func validate(
        registry: Registry,
        metadataDirectory: URL,
        payloadDirectory: URL
    ) throws -> ValidationReport {
        var errors = validateRegistry(registry)

        let registeredIDs = Set(registry.filters.map(\.id))
        let metadataEntries = try MetadataLoader.loadAll(from: metadataDirectory)

        var metadataByDeclaredID: [String: [String]] = [:] // declaredID -> [filenames]
        for entry in metadataEntries {
            let declaredID = entry.metadata.id
            let expectedFilename = "\(declaredID).json"
            if entry.filename != expectedFilename {
                errors.append(.metadataIDMismatch(filename: entry.filename, declaredID: declaredID))
            }
            metadataByDeclaredID[declaredID, default: []].append(entry.filename)
        }

        for (declaredID, filenames) in metadataByDeclaredID {
            if filenames.count > 1 {
                errors.append(.duplicateMetadata(id: declaredID))
            }
            if !registeredIDs.contains(declaredID) {
                errors.append(.orphanedMetadata(id: declaredID))
            }
        }

        for id in registeredIDs where metadataByDeclaredID[id] == nil {
            errors.append(.missingMetadata(id: id))
        }

        for entry in registry.filters {
            let payloadURL = payloadDirectory
                .appendingPathComponent(entry.group)
                .appendingPathComponent("\(entry.id).txt")
            if !FileManager.default.fileExists(atPath: payloadURL.path) {
                errors.append(.missingPayload(id: entry.id, expectedPath: payloadURL.path))
            }
        }

        return ValidationReport(errors: errors.sorted())
    }
}
