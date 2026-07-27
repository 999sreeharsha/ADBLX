import Foundation

enum ManifestBuilder {
    /// Assumes `registry`, `metadataByID`, and `payloadInfoByID` are already validated
    /// consistent (every registered filter has a metadata and payload entry) — Validator
    /// (Task 7) runs before this is ever called in the real `publish` pipeline.
    static func build(
        registry: Registry,
        metadataByID: [String: FilterMetadata],
        payloadInfoByID: [String: PayloadInfo],
        publishBaseURL: String
    ) -> Manifest {
        let entries: [ManifestEntry] = registry.filters.map { entry in
            let metadata = metadataByID[entry.id]!
            let payload = payloadInfoByID[entry.id]!
            let sourceURL = "\(publishBaseURL)/backend/public/filters/\(entry.group)/\(entry.id).txt"

            return ManifestEntry(
                id: entry.id,
                name: entry.name,
                group: entry.group,
                sourceURL: sourceURL,
                version: metadata.version,
                checksumSHA256: payload.checksumSHA256,
                ruleCount: payload.ruleCount,
                enabledByDefault: entry.enabledByDefault,
                premium: entry.premium
            )
        }.sorted { $0.id < $1.id }

        let manifestVersion = entries.map(\.version).max() ?? ""

        return Manifest(manifestVersion: manifestVersion, entries: entries)
    }
}
