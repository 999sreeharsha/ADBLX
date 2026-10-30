import Testing
import Foundation
@testable import ADBLX

/// A reconcile that arrives while an update transaction is running must WAIT for it and then
/// run — never be skipped (FilterTransactionGate "busy behavior"). Deterministic: no sleeps
/// or wall-clock thresholds; the update is parked at a known point and the gate queue observed.
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
        let session = HoldingHTTPSession(
            responses: [
                manifestURL: (try JSONEncoder().encode(manifest),
                    HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"e1\""])!),
                listURL: (listData, HTTPURLResponse(url: listURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            ],
            heldURL: listURL
        )
        // A private gate, so suites running in parallel on `.shared` cannot interleave.
        let gate = FilterTransactionGate()
        let entitlement = StubEntitlementService(isPremiumEntitled: false)
        let coordinator = UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestURL),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: ids, entitlementService: entitlement, gate: gate
        )
        let reconciler = PremiumEntitlementReconciler(
            store: store, pipeline: pipeline, manifestStore: ManifestStore(filterStore: store),
            reloader: ReloadCoordinator(), extensionIdentifiers: ids, entitlementService: entitlement, gate: gate
        )

        // 1. The update takes the gate and parks inside its download.
        let update = Task { try await coordinator.run() }
        await session.waitUntilHeld()

        // 2. The reconcile arrives and queues behind it.
        let finished = Flag()
        let reconcile = Task { () -> ReconcileOutcome in
            let outcome = await reconciler.reconcile()
            finished.set()
            return outcome
        }
        for _ in 0..<100_000 where await gate.waiterCount == 0 && !finished.isSet { await Task.yield() }
        #expect(await gate.waiterCount == 1, "reconcile did not queue behind the in-flight update")
        #expect(!finished.isSet, "reconcile finished while the update still held the gate")

        // 3. Let the update finish; only then may the reconcile run.
        session.release()
        let result = try await update.value
        let outcome = await reconcile.value

        guard case .updated = result else { Issue.record("expected .updated, got \(result)"); return }
        guard case .downgraded(let removed, _, _) = outcome else {
            Issue.record("reconcile was skipped or failed: \(outcome)"); return
        }
        #expect(removed == 1)

        let installed = try JSONDecoder().decode(
            [InstalledFilter].self, from: try await store.read("installed_filters.json", in: .metadata)
        )
        #expect(installed.map(\.id) == ["easylist"])
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Canned responses; the request for `heldURL` parks until `release()`, so a test can hold an
/// update transaction open at a known point instead of guessing with sleeps.
private final class HoldingHTTPSession: HTTPSession, @unchecked Sendable {
    private let responses: [URL: (Data, URLResponse)]
    private let heldURL: URL
    private let lock = NSLock()
    private var isHeld = false
    private var isReleased = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(responses: [URL: (Data, URLResponse)], heldURL: URL) {
        self.responses = responses
        self.heldURL = heldURL
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let response = responses[url] else { throw URLError(.badURL) }
        if url == heldURL {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                isHeld = true
                let waiter = heldWaiter
                heldWaiter = nil
                if isReleased {
                    lock.unlock()
                    continuation.resume()
                } else {
                    releaseWaiter = continuation
                    lock.unlock()
                }
                waiter?.resume()
            }
        }
        return response
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isHeld {
                lock.unlock()
                continuation.resume()
            } else {
                heldWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        isReleased = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}
