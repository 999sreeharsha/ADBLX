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
    private let gate: FilterTransactionGate
    private let pendingReloads: PendingReloads
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
        entitlementService: EntitlementService,
        gate: FilterTransactionGate = .shared,
        stateProvider: ContentBlockerStateProviding = SystemContentBlockerStateProvider()
    ) {
        self.manifestClient = manifestClient
        self.manifestStore = manifestStore
        self.downloadClient = downloadClient
        self.pipeline = pipeline
        self.store = store
        self.reloader = reloader
        self.extensionIdentifiers = extensionIdentifiers
        self.entitlementService = entitlementService
        self.gate = gate
        self.pendingReloads = PendingReloads(store: store, stateProvider: stateProvider)
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
        let task = Task {
            try await gate.run { try await runTransaction(onPhaseChange: onPhaseChange) }
        }
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
            let result = await upToDateResult()
            onPhaseChange(.complete)
            return result
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
        let keptFilterIDs = Set(plan.actions.compactMap { action -> String? in
            if case .keep(let filterID) = action { return filterID }
            return nil
        })
        let installedByID = Dictionary(installedFilters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let removals: [(filterID: String, group: FilterGroup)] = plan.actions.compactMap { action in
            guard case .remove(let filterID) = action else { return nil }
            guard let group = installedFilters.first(where: { $0.id == filterID })?.group else { return nil }
            return (filterID, group)
        }

        guard !installGroups.isEmpty || !removals.isEmpty else {
            try await manifestStore.save(manifest, etag: etag)
            let result = await upToDateResult()
            onPhaseChange(.complete)
            return result
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
            for (group, entries) in installGroups {
                let downloaded = downloadedByGroup[group] ?? []
                let sources = try await composeSources(
                    group: group, manifest: manifest, entries: entries,
                    downloaded: downloaded, keptFilterIDs: keptFilterIDs, installedByID: installedByID
                )
                let composition = GroupComposition(group: group, sources: sources)
                _ = try await pipeline.install(composition, reloadStrategy: .deferred)
                installedFilterIDs.append(contentsOf: downloaded.map(\.filterID))
            }
            for removal in removals {
                _ = try await pipeline.remove(filterID: removal.filterID, group: removal.group, reloadStrategy: .deferred)
            }
            try await manifestStore.save(manifest, etag: etag)
            try await store.discardRollbackSnapshot()
            let reloadResults = await reloader.reload(extensionIdentifiers: Array(affectedExtensionIDs))
            await pendingReloads.record(after: reloadResults)
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

    /// No new rules, but an earlier reload may have failed. The manifest is committed by then,
    /// so nothing else would ever reload that extension: a retry would get a 304 and report
    /// success while Safari still ran the old rules.
    private func upToDateResult() async -> UpdateRunResult {
        let pending = await pendingReloads.identifiers()
        guard !pending.isEmpty else { return .upToDate }
        let results = await reloader.reload(extensionIdentifiers: pending)
        await pendingReloads.record(after: results)
        guard await pendingReloads.includesEnabledFailure(results) else { return .upToDate }
        return .updated(installedFilterIDs: [], reloadResults: results)
    }

    private func currentInstalledFilters() async throws -> [InstalledFilter] {
        do {
            let data = try await store.read("installed_filters.json", in: .metadata)
            return try JSONDecoder().decode([InstalledFilter].self, from: data)
        } catch {
            return []
        }
    }

    /// A group compiles to one rule set, so it must be recomposed from ALL of its sources, not
    /// just the ones that changed: an unchanged sibling (e.g. Fanboy beside a new SHIELD fixes
    /// list) would otherwise vanish from the result. Sources stay in manifest order; unchanged
    /// ones come from the stored payload. A missing payload throws, which rolls the whole update
    /// back to the last-good rules rather than compiling the group without that source.
    private func composeSources(
        group: FilterGroup,
        manifest: FilterManifest,
        entries: [FilterManifest.Entry],
        downloaded: [DownloadedFilter],
        keptFilterIDs: Set<String>,
        installedByID: [String: InstalledFilter]
    ) async throws -> [FilterSource] {
        let premiumByID = Dictionary(entries.map { ($0.id, $0.premium) }, uniquingKeysWith: { first, _ in first })
        var downloadedByID: [String: DownloadedFilter] = [:]
        for filter in downloaded { downloadedByID[filter.filterID] = filter }

        var sources: [FilterSource] = []
        for entry in manifest.entries where entry.group == group {
            if let filter = downloadedByID[entry.id] {
                // Bridge because FilterPipeline.install is Data-based. If a future
                // overload accepts a URL directly, this read disappears.
                let data = try Data(contentsOf: filter.tempFileURL)
                sources.append(FilterSource(
                    filterID: filter.filterID,
                    version: filter.version,
                    checksumSHA256: filter.expectedChecksum,
                    data: data,
                    premium: premiumByID[filter.filterID] ?? false
                ))
            } else if keptFilterIDs.contains(entry.id), let installed = installedByID[entry.id] {
                sources.append(FilterSource(
                    filterID: installed.id,
                    version: installed.installedVersion,
                    checksumSHA256: installed.checksumSHA256,
                    data: try await store.readFilterPayload(filterID: installed.id),
                    premium: entry.premium
                ))
            }
        }
        return sources
    }
}
