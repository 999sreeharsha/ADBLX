import Testing
import Foundation
@testable import ADBLX

/// A reconcile that arrives while an update transaction is running must WAIT for it and then
/// run — never be skipped (FilterTransactionGate "busy behavior").
@Suite("Reconcile during update", .serialized)
struct ReconcileDuringUpdateTests {
    private let manifestURL = URL(string: "https://example.com/manifest.json")!
    private let listURL = URL(string: "https://example.com/easylist.json")!
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    @Test("reconcile started mid-update waits, then downgrades; update still commits")
    func reconcileWaitsForInFlightUpdate() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ReconcileDuring_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = FilterStore(overrideBaseURL: temp)
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )

        // A premium Annoyances list is already installed; the user is no longer entitled.
        let premiumData = Data("[{\"trigger\":{\"url-filter\":\"cookie\"},\"action\":{\"type\":\"block\"}}]".utf8)
        _ = try await pipeline.install(GroupComposition(group: .annoyances, sources: [FilterSource(
            filterID: "fanboy-annoyances", version: "v1", checksumSHA256: Checksum.sha256Hex(of: premiumData),
            data: premiumData, premium: true
        )]), reloadStrategy: .deferred)

        // The update will install a new free Ads list. Each HTTP call is slow, so the
        // transaction holds the gate for a while.
        let listData = Data("[{\"trigger\":{\"url-filter\":\"ads\"},\"action\":{\"type\":\"block\"}}]".utf8)
        let manifest = FilterManifest(manifestVersion: "1", entries: [
            .init(id: "easylist", name: "EasyList", group: .ads, sourceURL: listURL, version: "2026-10-29",
                  checksumSHA256: Checksum.sha256Hex(of: listData), ruleCount: 1, enabledByDefault: true, premium: false),
            .init(id: "fanboy-annoyances", name: "Annoyances", group: .annoyances, sourceURL: listURL, version: "v1",
                  checksumSHA256: Checksum.sha256Hex(of: premiumData), ruleCount: 1, enabledByDefault: true, premium: true)
        ])
        let session = MockHTTPSession(responses: [
            manifestURL: .success((try JSONEncoder().encode(manifest),
                HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"e1\""])!)),
            listURL: .success((listData, HTTPURLResponse(url: listURL, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        ], delayNanoseconds: 300_000_000)
        let entitlement = StubEntitlementService(isPremiumEntitled: false)
        let coordinator = UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestURL),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: ids, entitlementService: entitlement
        )
        let reconciler = PremiumEntitlementReconciler(
            store: store, pipeline: pipeline, manifestStore: ManifestStore(filterStore: store),
            reloader: ReloadCoordinator(), extensionIdentifiers: ids, entitlementService: entitlement
        )

        let update = Task { try await coordinator.run() }
        try await Task.sleep(nanoseconds: 100_000_000)   // update now holds the gate (>= ~500 ms left)

        let started = Date()
        let outcome = await reconciler.reconcile()
        let waited = Date().timeIntervalSince(started)

        let result = try await update.value
        guard case .updated = result else { Issue.record("expected .updated, got \(result)"); return }
        guard case .downgraded(let removed, _, _) = outcome else {
            Issue.record("reconcile was skipped or failed: \(outcome)"); return
        }
        #expect(removed == 1)
        #expect(waited >= 0.3, "reconcile returned after \(waited)s — it did not wait for the in-flight update")

        let installed = try JSONDecoder().decode(
            [InstalledFilter].self, from: try await store.read("installed_filters.json", in: .metadata)
        )
        #expect(installed.map(\.id) == ["easylist"])
    }
}
