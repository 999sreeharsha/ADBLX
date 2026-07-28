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
    private let entitlementService: EntitlementService
    private var inFlightTask: Task<UpdateRunResult, Error>?
    // Bumped each time a NEW transaction task is created. `Task` is a struct with no
    // identity comparison, so this generation counter is what lets the creator of a
    // task recognize "is `inFlightTask` still the task I created, or has someone else
    // since replaced it with a newer one" — see run()'s defer below and the Sprint 8.0
    // final-review fix for the 3+-caller in-flight-guard bug.
    private var inFlightGeneration = 0

    init(
        manifestClient: ManifestClient,
        manifestStore: ManifestStore,
        downloadClient: FilterDownloadClient,
        pipeline: FilterPipeline,
        store: FilterStore,
        reloader: ReloadCoordinator,
        extensionIdentifiers: GroupExtensionIdentifiers,
        entitlementService: EntitlementService
    ) {
        self.manifestClient = manifestClient
        self.manifestStore = manifestStore
        self.downloadClient = downloadClient
        self.pipeline = pipeline
        self.store = store
        self.reloader = reloader
        self.extensionIdentifiers = extensionIdentifiers
        self.entitlementService = entitlementService
    }

    /// `onPhaseChange` is additive — defaults to a no-op so existing callers (and
    /// UpdateCoordinatorTests) are unaffected. Called at four checkpoints matching
    /// UpdatePhase's in-flight cases: before the manifest fetch (.checking), before
    /// the download+verify loop (.downloading), before the per-group install loop
    /// (.installing), and on completion (.complete/.failed via the caller's catch,
    /// since run() throws rather than returning a .failed case itself — see
    /// UpdateProgressModel.start(coordinator:) in Sprint 5B Commit 2).
    ///
    /// Concurrent callers while a transaction is already running await the same
    /// in-flight Task rather than starting a second transaction — actor isolation
    /// alone only serializes execution, it does not prevent two full transactions
    /// from each running to completion (Sprint 8.0 Commit 2).
    func run(onPhaseChange: @escaping (UpdatePhase) -> Void = { _ in }) async throws -> UpdateRunResult {
        // A caller that merely JOINS an already-running transaction must never touch
        // `inFlightTask`/`inFlightGeneration` — no defer, no side effect beyond
        // returning the joined result. Only the caller that actually creates a task
        // (below) is allowed to clear the shared state, and only if it can prove
        // nobody has since replaced its task with a newer one.
        if let inFlightTask {
            return try await inFlightTask.value
        }
        inFlightGeneration += 1
        let myGeneration = inFlightGeneration
        let task = Task { try await runTransaction(onPhaseChange: onPhaseChange) }
        inFlightTask = task
        defer {
            // Only reset if `inFlightTask` still refers to the task THIS invocation
            // created — i.e. no other caller has since started a newer transaction
            // (which would have bumped `inFlightGeneration` past `myGeneration` and
            // installed its own task). Without this generation check, a caller that
            // created task A could clobber a later caller's task C out from under it
            // once A finishes, even though C is still running.
            if inFlightGeneration == myGeneration {
                inFlightTask = nil
            }
            try? downloadClient.cleanupWorkspace()
        }
        return try await task.value
    }

    private func runTransaction(onPhaseChange: (UpdatePhase) -> Void) async throws -> UpdateRunResult {
        onPhaseChange(.checking)
        let cached = try await manifestStore.load()
        let fetchResult = try await manifestClient.fetch(previousETag: cached?.etag)

        let manifest: FilterManifest
        let etag: String?
        switch fetchResult {
        case .notModified:
            onPhaseChange(.complete)
            return .upToDate
        case .updated(let fetchedManifest, let fetchedETag):
            manifest = fetchedManifest
            etag = fetchedETag
        }

        let installedFilters = try await currentInstalledFilters()
        let isPremiumEntitled = await entitlementService.isPremiumEntitled()
        let plan = UpdatePlanner.plan(manifest: manifest, installed: installedFilters, isPremiumEntitled: isPremiumEntitled)
        let installGroups: [(group: FilterGroup, entries: [FilterManifest.Entry])] = plan.actions.compactMap {
            if case .install(let group, let entries) = $0 { return (group, entries) }
            return nil
        }
        let removals: [(filterID: String, group: FilterGroup)] = plan.actions.compactMap { action in
            guard case .remove(let filterID) = action else { return nil }
            guard let group = installedFilters.first(where: { $0.id == filterID })?.group else { return nil }
            return (filterID, group)
        }

        guard !installGroups.isEmpty || !removals.isEmpty else {
            try await manifestStore.save(manifest, etag: etag)
            onPhaseChange(.complete)
            return .upToDate
        }

        onPhaseChange(.downloading)
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

        // Snapshot before any write in the batch begins — this must capture pre-transaction
        // Filters/ state before any removal in the batch executes (Sprint 8.0 Commit 3).
        let snapshot = try await store.snapshotForRollback()
        // De-duplicated but order-preserving (first occurrence wins) — a plain `Set` would
        // reload every affected extension exactly once too, but in hash-order rather than
        // manifest/plan order, which breaks callers (and this file's own
        // manifestAcrossAllGroupsInstallsEachGroupOnce test) that depend on
        // ReloadCoordinator.reload(extensionIdentifiers:) producing results in a stable,
        // predictable sequence.
        var affectedExtensionIDs: [String] = []
        for identifier in installGroups.map({ extensionIdentifiers[$0.group] }) + removals.map({ extensionIdentifiers[$0.group] }) {
            if !affectedExtensionIDs.contains(identifier) {
                affectedExtensionIDs.append(identifier)
            }
        }
        var installedFilterIDs: [String] = []

        onPhaseChange(.installing)
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
            for removal in removals {
                _ = try await pipeline.remove(filterID: removal.filterID, group: removal.group, reloadStrategy: .deferred)
            }
            try await manifestStore.save(manifest, etag: etag)
            let reloadResults = await reloader.reload(extensionIdentifiers: Array(affectedExtensionIDs))
            onPhaseChange(.complete)
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
            _ = await reloader.reload(extensionIdentifiers: Array(affectedExtensionIDs))
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
