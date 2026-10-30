import Foundation
import OSLog

enum ReconcileOutcome: Equatable {
    /// Installed premium filters already match entitlement. No rule file was written and no
    /// extension was reloaded.
    case noChange
    /// Not entitled and premium filters were installed: they were removed and the affected
    /// groups recompiled from their remaining (free) sources.
    case downgraded(removedCount: Int, affectedGroups: [FilterGroup], reloadFailures: Int)
    /// Entitled and a default premium list was missing: reinstalled from the bundle, and the
    /// cached manifest's ETag was cleared so the next update does a full fetch.
    case restored(installedCount: Int)
    /// The batch failed part-way and the whole transaction was rolled back.
    case rolledBack
    /// Rollback itself failed. Surfaced distinctly, never swallowed.
    case rollbackFailed
}

/// Level-triggered: every run compares what is installed against current entitlement and
/// corrects any difference, so it is correct no matter which event (launch, foreground,
/// entitlement change, refund while open, or a transition missed while the app was closed)
/// caused the run. There is deliberately no "last reconciled" state.
///
/// Entitlement-source agnostic: trial expiry, subscription lapse and refund/revocation all
/// arrive as `EntitlementService` reporting no premium access.
///
/// Group-generic: nothing here names Annoyances or Regional. Premium-ness comes from
/// `InstalledFilter.premium`, resolved for legacy records from the cached manifest and then
/// `BundledPremiumCatalog`.
///
/// Logging (docs/Architecture/Logging.md): outcome case names and counts only.
actor PremiumEntitlementReconciler {
    private let store: FilterStore
    private let pipeline: FilterPipeline
    private let manifestStore: ManifestStore
    private let reloader: ReloadCoordinator
    private let extensionIdentifiers: GroupExtensionIdentifiers
    private let entitlementService: EntitlementService
    private let gate: FilterTransactionGate

    private var observationTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "PremiumEntitlementReconciler")
    private static let signposter = OSSignposter(subsystem: "com.ADBLX.ADBLX", category: "PremiumEntitlementReconciler")

    init(
        store: FilterStore,
        pipeline: FilterPipeline,
        manifestStore: ManifestStore,
        reloader: ReloadCoordinator,
        extensionIdentifiers: GroupExtensionIdentifiers,
        entitlementService: EntitlementService,
        gate: FilterTransactionGate = .shared
    ) {
        self.store = store
        self.pipeline = pipeline
        self.manifestStore = manifestStore
        self.reloader = reloader
        self.extensionIdentifiers = extensionIdentifiers
        self.entitlementService = entitlementService
        self.gate = gate
    }

    /// Reconciles on every `EntitlementService` state change (purchase, lapse, a refund while
    /// the app is open arriving via `Transaction.updates`). Idempotent to call twice.
    func startObserving() {
        guard observationTask == nil else { return }
        let service = entitlementService
        observationTask = Task { [weak self] in
            for await _ in service.stateUpdates() {
                guard let self else { return }
                await self.reconcile()
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    @discardableResult
    func reconcile() async -> ReconcileOutcome {
        let interval = Self.signposter.beginInterval("entitlement.reconcile", id: Self.signposter.makeSignpostID())
        // Refresh first so a lapse or refund the app hasn't seen yet is not missed.
        let state = await entitlementService.refreshEntitlements()
        // Waits for any in-flight update/downgrade (see FilterTransactionGate) rather than skipping.
        let outcome = await gate.run {
            #if DEBUG
            // This is an actor, so its work must never land on the main thread (NFR-05).
            dispatchPrecondition(condition: .notOnQueue(.main))
            #endif
            return state.hasPremiumAccess ? await restoreIfNeeded() : await downgradeIfNeeded()
        }
        Self.signposter.endInterval("entitlement.reconcile", interval, "\(Self.caseName(of: outcome), privacy: .public)")
        if outcome != .noChange {
            Self.logger.info("reconcile outcome=\(Self.name(of: outcome), privacy: .public)")
        }
        return outcome
    }

    // MARK: - Downgrade

    private func downgradeIfNeeded() async -> ReconcileOutcome {
        var installed = await readInstalled()
        guard !installed.isEmpty else { return .noChange }

        installed = await resolveLegacyFlags(installed)
        let premium = installed.filter { $0.premium == true }
        guard !premium.isEmpty else { return .noChange }

        var idsByGroup: [FilterGroup: Set<String>] = [:]
        for filter in premium { idsByGroup[filter.group, default: []].insert(filter.id) }
        let groups = idsByGroup.keys.sorted { $0.rawValue < $1.rawValue }

        let snapshot: RollbackSnapshot
        do {
            snapshot = try await store.snapshotForRollback()
        } catch {
            Self.logger.error("downgrade snapshot failed")
            return .rollbackFailed
        }

        do {
            for group in groups {
                _ = try await pipeline.remove(filterIDs: idsByGroup[group] ?? [], group: group, reloadStrategy: .deferred)
            }
            try await store.discardRollbackSnapshot()
        } catch {
            do {
                try await store.restore(snapshot)
            } catch {
                Self.logger.error("downgrade rollback failed")
                return .rollbackFailed
            }
            _ = await reloader.reload(extensionIdentifiers: groups.map { identifier(for: $0) })
            return .rolledBack
        }

        let results = await reloader.reload(extensionIdentifiers: groups.map { identifier(for: $0) })
        let failures = results.filter { !$0.success }.count
        return .downgraded(removedCount: premium.count, affectedGroups: groups, reloadFailures: failures)
    }

    /// Records written before `premium` existed carry `nil`. Resolve from the cached manifest,
    /// then the bundled catalog, and persist so later runs need no lookup.
    private func resolveLegacyFlags(_ installed: [InstalledFilter]) async -> [InstalledFilter] {
        guard installed.contains(where: { $0.premium == nil }) else { return installed }
        let manifestEntries = (try? await manifestStore.load())?.manifest.entries ?? []
        let manifestPremiumByID = Dictionary(manifestEntries.map { ($0.id, $0.premium) }, uniquingKeysWith: { first, _ in first })

        var resolved = installed
        for index in resolved.indices where resolved[index].premium == nil {
            let id = resolved[index].id
            resolved[index].premium = manifestPremiumByID[id] ?? BundledPremiumCatalog.isPremium(filterID: id)
        }
        if let data = try? JSONEncoder().encode(resolved) {
            try? await store.writeMetadata(data, filename: "installed_filters.json")
        }
        return resolved
    }

    // MARK: - Restore

    private func restoreIfNeeded() async -> ReconcileOutcome {
        let installedIDs = Set(await readInstalled().map(\.id))
        let cached = try? await manifestStore.load()

        var expected = Set(BundledPremiumCatalog.bundledEntries.map(\.filterID))
        for entry in cached?.manifest.entries ?? [] where entry.premium && entry.enabledByDefault {
            expected.insert(entry.id)
        }
        guard !expected.isSubset(of: installedIDs) else { return .noChange }

        // Instant, offline baseline for what ships in the bundle...
        let results = await pipeline.installBundledPremiumSnapshot(reloadStrategy: .immediate)
        // ...and force the next update run to re-evaluate the manifest from scratch, since an
        // unchanged (304) manifest would otherwise never install premium lists it lacks.
        if let cached {
            try? await manifestStore.save(cached.manifest, etag: nil)
        }
        return .restored(installedCount: results.count)
    }

    // MARK: - Helpers

    private func readInstalled() async -> [InstalledFilter] {
        guard let data = try? await store.read("installed_filters.json", in: .metadata),
              let decoded = try? JSONDecoder().decode([InstalledFilter].self, from: data) else {
            return []
        }
        return decoded
    }

    private func identifier(for group: FilterGroup) -> String {
        extensionIdentifiers[group]
    }

    /// Bare enum case name only — safe for signposts.
    private static func caseName(of outcome: ReconcileOutcome) -> String {
        switch outcome {
        case .noChange: return "noChange"
        case .downgraded: return "downgraded"
        case .restored: return "restored"
        case .rolledBack: return "rolledBack"
        case .rollbackFailed: return "rollbackFailed"
        }
    }

    private static func name(of outcome: ReconcileOutcome) -> String {
        switch outcome {
        case .noChange: return "noChange"
        case .downgraded(let removed, let groups, let failures):
            return "downgraded removed=\(removed) groups=\(groups.count) reloadFailures=\(failures)"
        case .restored(let count): return "restored installed=\(count)"
        case .rolledBack: return "rolledBack"
        case .rollbackFailed: return "rollbackFailed"
        }
    }
}
