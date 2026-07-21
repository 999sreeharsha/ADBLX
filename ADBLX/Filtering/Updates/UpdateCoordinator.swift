import Foundation

enum UpdateRunResult {
    case upToDate
    case updated(installedFilterIDs: [String], reloadResults: [ReloadCoordinator.ReloadResult])
    case rolledBack(reason: Error)
    case rollbackFailed(originalReason: Error, restoreError: Error)
}

/// Orchestrates one full update transaction: fetch manifest → plan (grouped by
/// `FilterGroup`) → download + verify each group → compose + install one
/// `GroupComposition` per affected group (deferred reload) → commit metadata + reload
/// once per affected extension, or roll back the entire batch and reload once with the
/// restored state on any failure past the checksum-verification point. See the Sprint 2
/// and Sprint 3A design docs for the full data flow.
actor UpdateCoordinator {
    private let manifestClient: ManifestClient
    private let manifestStore: ManifestStore
    private let downloadClient: FilterDownloadClient
    private let pipeline: FilterPipeline
    private let store: FilterStore
    private let reloader: ReloadCoordinator
    private let extensionIdentifiers: GroupExtensionIdentifiers

    init(
        manifestClient: ManifestClient,
        manifestStore: ManifestStore,
        downloadClient: FilterDownloadClient,
        pipeline: FilterPipeline,
        store: FilterStore,
        reloader: ReloadCoordinator,
        extensionIdentifiers: GroupExtensionIdentifiers
    ) {
        self.manifestClient = manifestClient
        self.manifestStore = manifestStore
        self.downloadClient = downloadClient
        self.pipeline = pipeline
        self.store = store
        self.reloader = reloader
        self.extensionIdentifiers = extensionIdentifiers
    }

    func run() async throws -> UpdateRunResult {
        let cached = try await manifestStore.load()
        let fetchResult = try await manifestClient.fetch(previousETag: cached?.etag)

        let manifest: FilterManifest
        let etag: String?
        switch fetchResult {
        case .notModified:
            return .upToDate
        case .updated(let fetchedManifest, let fetchedETag):
            manifest = fetchedManifest
            etag = fetchedETag
        }

        let installedFilters = try await currentInstalledFilters()
        let plan = UpdatePlanner.plan(manifest: manifest, installed: installedFilters)
        let installGroups: [(group: FilterGroup, entries: [FilterManifest.Entry])] = plan.actions.compactMap {
            if case .install(let group, let entries) = $0 { return (group, entries) }
            return nil
        }

        guard !installGroups.isEmpty else {
            try await manifestStore.save(manifest, etag: etag)
            return .upToDate
        }

        // Download and verify every group up front, before any write — a checksum
        // failure in one group must not leave another group's files half-written.
        var downloadedByGroup: [FilterGroup: [DownloadedFilter]] = [:]
        for (group, entries) in installGroups {
            var downloaded: [DownloadedFilter] = []
            for entry in entries {
                downloaded.append(try await downloadClient.download(entry))
            }
            for filter in downloaded {
                try Checksum.verify(fileURL: filter.tempFileURL, against: filter.expectedChecksum)
            }
            downloadedByGroup[group] = downloaded
        }

        let snapshot = try await store.snapshotForRollback()
        let affectedExtensionIDs = installGroups.map { extensionIdentifiers[$0.group] }
        var installedFilterIDs: [String] = []

        do {
            // One group composed and installed at a time — keeps at most one group's
            // decoded sources resident in memory (Sprint 3A design doc's <200MB target).
            for (group, _) in installGroups {
                let downloaded = downloadedByGroup[group] ?? []
                var sources: [FilterSource] = []
                for filter in downloaded {
                    // Bridge because FilterPipeline.install is Data-based. If a future
                    // overload accepts a URL directly, this read disappears.
                    let data = try Data(contentsOf: filter.tempFileURL)
                    sources.append(FilterSource(
                        filterID: filter.filterID,
                        version: filter.version,
                        checksumSHA256: filter.expectedChecksum,
                        data: data
                    ))
                }
                let composition = GroupComposition(group: group, sources: sources)
                _ = try await pipeline.install(composition, reloadStrategy: .deferred)
                installedFilterIDs.append(contentsOf: downloaded.map(\.filterID))
            }
            try await manifestStore.save(manifest, etag: etag)
            let reloadResults = await reloader.reload(extensionIdentifiers: affectedExtensionIDs)
            return .updated(installedFilterIDs: installedFilterIDs, reloadResults: reloadResults)
        } catch {
            do {
                try await store.restore(snapshot)
            } catch let restoreError {
                // `store.restore` only deletes `Previous/` after both directory
                // replacements succeed, so a thrown restoreError here means the
                // snapshot is still on disk — do not attempt a second automatic
                // retry; surface both failures distinctly instead of losing the
                // original install failure or crashing the caller with a raw throw.
                return .rollbackFailed(originalReason: error, restoreError: restoreError)
            }
            _ = await reloader.reload(extensionIdentifiers: affectedExtensionIDs)
            return .rolledBack(reason: error)
        }
    }

    private func currentInstalledFilters() async throws -> [InstalledFilter] {
        do {
            let data = try await store.read("installed_filters.json", in: .metadata)
            return try JSONDecoder().decode([InstalledFilter].self, from: data)
        } catch {
            return []
        }
    }
}
