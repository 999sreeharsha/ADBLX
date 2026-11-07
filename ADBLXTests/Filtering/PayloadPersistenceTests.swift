import Testing
import Foundation
@testable import ADBLX

/// Every install path must persist each source's raw payload to `Filters/`: a later update
/// recomposes a multi-source group from those payloads (UpdateCoordinator.composeSources),
/// and a missing one throws and rolls the update back.
@Suite("Payload persistence across install paths", .serialized)
struct PayloadPersistenceTests {
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )
    private let manifestEndpoint = URL(string: "https://example.com/manifest.json")!
    private let fixesURL = URL(string: "https://example.com/filters/annoyances/shield-fixes.txt")!

    private func makePipeline(_ store: FilterStore) -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(), compiler: NativeRuleCompilerAdapter(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
    }

    private func bundled(_ name: String) throws -> Data {
        let url = Bundle.main.url(forResource: name, withExtension: "txt")
            ?? Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Filters")
        return try Data(contentsOf: try #require(url, "\(name).txt missing from the app bundle"))
    }

    private func installed(_ store: FilterStore) async throws -> [InstalledFilter] {
        try JSONDecoder().decode([InstalledFilter].self, from: try await store.read("installed_filters.json", in: .metadata))
    }

    /// Every installed filter has a non-empty stored payload.
    private func expectPayloadsPersisted(_ store: FilterStore, ids expected: Set<String>) async throws {
        let filters = try await installed(store)
        #expect(Set(filters.map(\.id)) == expected)
        for filter in filters {
            let payload = try await store.readFilterPayload(filterID: filter.id)
            #expect(!payload.isEmpty, "\(filter.id) has no stored payload")
        }
    }

    @Test("bundled snapshot (free + premium) persists every list's payload")
    func bundledSnapshotPersists() async throws {
        let store = FilterStore.temporary()
        _ = try await makePipeline(store).installBundledSnapshotIfNeeded(includePremium: true)
        try await expectPayloadsPersisted(store, ids: ["easylist", "easyprivacy", "fanboy-annoyances", "shield-fixes"])
    }

    @Test("the reconciler's bundled install of a missing premium list persists its payload")
    func reconcilerInstallPersists() async throws {
        let store = FilterStore.temporary()
        let pipeline = makePipeline(store)
        let fanboy = try bundled("fanboy-annoyances")
        _ = try await pipeline.install(GroupComposition(group: .annoyances, sources: [
            FilterSource(filterID: "fanboy-annoyances", version: "bundled-baseline",
                         checksumSHA256: Checksum.sha256Hex(of: fanboy), data: fanboy, premium: true)
        ]), reloadStrategy: .deferred)

        let reconciler = PremiumEntitlementReconciler(
            store: store, pipeline: pipeline, manifestStore: ManifestStore(filterStore: store),
            reloader: ReloadCoordinator(), extensionIdentifiers: ids,
            entitlementService: MockSubscriptionService(state: .lifetime)
        )
        guard case .restored = await reconciler.reconcile() else {
            Issue.record("expected the reconciler to restore the missing shield-fixes list"); return
        }
        try await expectPayloadsPersisted(store, ids: ["fanboy-annoyances", "shield-fixes"])
    }

    /// Fresh bundled install, then an update where Fanboy is unchanged and shield-fixes is new.
    private func freshInstallThenUpdate() async throws -> (
        store: FilterStore, fanboyRules: Int, compiledRules: Int, updatedIDs: [String], duration: Double, peakDeltaMB: Double
    ) {
        let store = FilterStore.temporary()
        let pipeline = makePipeline(store)
        let fanboy = try bundled("fanboy-annoyances")
        let fixes = try bundled("shield-fixes")

        // Fresh install: Fanboy only, as a user who had Premium before the fixes list existed.
        _ = try await pipeline.install(GroupComposition(group: .annoyances, sources: [
            FilterSource(filterID: "fanboy-annoyances", version: "bundled-baseline",
                         checksumSHA256: Checksum.sha256Hex(of: fanboy), data: fanboy, premium: true)
        ]), reloadStrategy: .deferred)

        // OTA: Fanboy unchanged (kept), shield-fixes new.
        let newFixes = fixes + Data("\n###SomeOtherBanner\n".utf8)
        let entries = [
            FilterManifest.Entry(
                id: "fanboy-annoyances", name: "Fanboy", group: .annoyances,
                sourceURL: URL(string: "https://example.com/filters/annoyances/fanboy-annoyances.txt")!, version: "bundled-baseline",
                checksumSHA256: Checksum.sha256Hex(of: fanboy), ruleCount: 1, enabledByDefault: false, premium: true),
            FilterManifest.Entry(
                id: "shield-fixes", name: "SHIELD Fixes", group: .annoyances, sourceURL: fixesURL,
                version: "2026-11-06", checksumSHA256: Checksum.sha256Hex(of: newFixes), ruleCount: 2,
                enabledByDefault: false, premium: true),
        ]
        let session = MockHTTPSession(responses: [
            manifestEndpoint: .success((
                try JSONEncoder().encode(FilterManifest(manifestVersion: SignedManifests.version, entries: entries)),
                HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v2\""])!
            )),
            fixesURL: .success((newFixes, HTTPURLResponse(url: fixesURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)),
        ])
        let coordinator = UpdateCoordinator(
            manifestClient: SignedManifests.signingClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(), extensionIdentifiers: ids,
            entitlementService: StubEntitlementService(isPremiumEntitled: true)
        )

        let baselineMB = FootprintSampler.currentMB()
        let sampler = FootprintSampler(initialMB: baselineMB)
        sampler.start()
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await coordinator.run()
        let duration = CFAbsoluteTimeGetCurrent() - start
        let peak = sampler.stop()

        guard case .updated(let updatedIDs, _) = result else {
            Issue.record("expected .updated, got \(result)")
            return (store, 0, 0, [], duration, peak - baselineMB)
        }
        let compiled = try JSONSerialization.jsonObject(with: try await store.read("Annoyances.json", in: .compiled)) as? [Any]
        let fanboyAlone = try NativeABPRuleCompiler.compile(source: fanboy, group: "annoyances").rules.count
        return (store, fanboyAlone, compiled?.count ?? 0, updatedIDs, duration, peak - baselineMB)
    }

    @Test("fresh install then OTA update: the unchanged source survives and every payload is persisted")
    func freshInstallThenUpdatePersists() async throws {
        let run = try await freshInstallThenUpdate()
        #expect(run.updatedIDs == ["shield-fixes"])
        // Fanboy's rules (from its stored payload) plus the two fix rules.
        #expect(run.compiledRules == run.fanboyRules + 2)
        try await expectPayloadsPersisted(run.store, ids: ["fanboy-annoyances", "shield-fixes"])
    }

    // Measured, not asserted: see docs/AppStoreSetup.md (Release Checklist) for NFR-01.
    @Test("Fanboy + shield-fixes recompose through the update path completes and reports its cost")
    func recomposeStaysWithinBudget() async throws {
        let run = try await freshInstallThenUpdate()
        print("[recompose] Fanboy + shield-fixes via update path: \(String(format: "%.2f", run.duration)) s, "
              + "peak footprint delta \(String(format: "%.1f", run.peakDeltaMB)) MB")
        #expect(run.compiledRules > 0)
    }
}

/// Samples this process's physical footprint on a background thread and keeps the peak.
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var peak: Double

    init(initialMB: Double) { peak = initialMB }

    static func currentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / (1024.0 * 1024.0) : 0
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                lock.lock()
                let keepGoing = running
                if keepGoing { peak = max(peak, Self.currentMB()) }
                lock.unlock()
                if !keepGoing { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    func stop() -> Double {
        lock.lock()
        running = false
        peak = max(peak, Self.currentMB())
        defer { lock.unlock() }
        return peak
    }
}
