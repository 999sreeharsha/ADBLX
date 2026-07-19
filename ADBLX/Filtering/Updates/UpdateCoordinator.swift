import Foundation

enum UpdateRunResult {
    case upToDate
    case updated(installedFilterIDs: [String], reloadResults: [ReloadCoordinator.ReloadResult])
    case rolledBack(reason: Error)
    case rollbackFailed(originalReason: Error, restoreError: Error)
}

/// Orchestrates one full update transaction: fetch manifest → plan → download → verify
/// → install (deferred reload) → commit metadata + single reload, or roll back the
/// entire batch and reload once with the restored state on any failure past the
/// checksum-verification point. See the Sprint 2 design doc for the full data flow and
/// the `.ads`-only / group-conflict limitations this sprint operates under.
actor UpdateCoordinator {
    private let manifestClient: ManifestClient
    private let manifestStore: ManifestStore
    private let downloadClient: FilterDownloadClient
    private let pipeline: FilterPipeline
    private let store: FilterStore
    private let reloader: ReloadCoordinator
    private let adsExtensionIdentifier: String

    init(
        manifestClient: ManifestClient,
        manifestStore: ManifestStore,
        downloadClient: FilterDownloadClient,
        pipeline: FilterPipeline,
        store: FilterStore,
        reloader: ReloadCoordinator,
        adsExtensionIdentifier: String
    ) {
        self.manifestClient = manifestClient
        self.manifestStore = manifestStore
        self.downloadClient = downloadClient
        self.pipeline = pipeline
        self.store = store
        self.reloader = reloader
        self.adsExtensionIdentifier = adsExtensionIdentifier
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
        let installs: [FilterManifest.Entry] = plan.actions.compactMap {
            if case .install(let entry) = $0 { return entry }
            return nil
        }

        guard !installs.isEmpty else {
            try await manifestStore.save(manifest, etag: etag)
            return .upToDate
        }

        var downloaded: [DownloadedFilter] = []
        for entry in installs {
            downloaded.append(try await downloadClient.download(entry))
        }
        for filter in downloaded {
            try Checksum.verify(fileURL: filter.tempFileURL, against: filter.expectedChecksum)
        }

        let snapshot = try await store.snapshotForRollback()
        // .ads is the only routable group this sprint — see the Sprint 2 design doc's
        // "Known dependency on Sprint 1's partitioning scope."
        let affectedExtensionIDs = [adsExtensionIdentifier]

        do {
            for filter in downloaded {
                // Bridge because FilterPipeline.install is Data-based from Sprint 1. If
                // a future overload accepts a URL directly, this read disappears.
                let data = try Data(contentsOf: filter.tempFileURL)
                // version: filter.version is required, not cosmetic — UpdatePlanner compares
                // InstalledFilter.installedVersion against FilterManifest.Entry.version to
                // decide .keep vs .install on the next run. Omitting it (leaving the
                // "bundled-snapshot" default) would make this filter never converge to
                // .keep, defeating "download only changed filters" on every subsequent run.
                _ = try await pipeline.install(filterID: filter.filterID, source: data, version: filter.version, reloadStrategy: .deferred)
            }
            try await manifestStore.save(manifest, etag: etag)
            let reloadResults = await reloader.reload(extensionIdentifiers: affectedExtensionIDs)
            return .updated(installedFilterIDs: downloaded.map(\.filterID), reloadResults: reloadResults)
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
