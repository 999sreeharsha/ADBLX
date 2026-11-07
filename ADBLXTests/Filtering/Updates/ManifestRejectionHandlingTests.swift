import Foundation
import Testing
@testable import ADBLX

/// A rejected manifest is a soft failure (docs/Security/ManifestTrust.md, "When verification
/// fails"): nothing changes, the user sees the same text as for a network failure, and the
/// next check waits for the throttle like after a success.
@Suite("Manifest rejection handling", .serialized)
struct ManifestRejectionHandlingTests {
    private let endpoint = URL(string: "https://example.com/adblx/manifest.json")!
    private let ids = AppCompositionRoot.extensionIdentifiers

    private func smallPipeline(_ store: FilterStore) -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator(), gate: FilterTransactionGate()
        )
    }

    private func coordinator(
        store: FilterStore, pipeline: FilterPipeline? = nil, session: HTTPSession, verifier: ManifestVerifier? = nil,
        rejectionLog: ManifestRejectionLog = ManifestRejectionLog()
    ) -> UpdateCoordinator {
        UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: endpoint, verifier: verifier ?? SignedManifests.verifier(for: endpoint)),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline ?? smallPipeline(store), store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: ids, entitlementService: StubEntitlementService(isPremiumEntitled: false),
            gate: FilterTransactionGate(), rejectionLog: rejectionLog
        )
    }

    /// Serves an unsigned manifest, so every fetch is rejected on its signature.
    private func unsignedSession(version: String = SignedManifests.version) -> CountingSession {
        let manifest = FilterManifest(manifestVersion: version, entries: [])
        return CountingSession(MockHTTPSession(responses: [
            endpoint: .success((try! JSONEncoder().encode(manifest), HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        ]))
    }

    // MARK: Throttle

    @Test("After a rejection, a launch inside the throttle window makes no request")
    func rejectionAdvancesTheThrottle() async throws {
        let store = FilterStore.temporary()
        let session = unsignedSession()
        let coordinator = coordinator(store: store, session: session)
        let throttle = UpdateThrottle(store: store, interval: 6 * 3_600)
        let start = Date()

        let ranFirst = await AutomaticUpdate.runIfDue(coordinator: coordinator, throttle: throttle, now: start)
        let afterFirst = session.count
        let ranSecond = await AutomaticUpdate.runIfDue(coordinator: coordinator, throttle: throttle, now: start.addingTimeInterval(3_600))

        #expect(ranFirst)
        #expect(!ranSecond)
        #expect(afterFirst > 0)
        #expect(session.count == afterFirst)
    }

    @Test("After a network failure, the next launch checks again")
    func networkFailureLeavesTheThrottle() async throws {
        let store = FilterStore.temporary()
        let session = CountingSession(MockHTTPSession(responses: [endpoint: .failure(URLError(.notConnectedToInternet))]))
        let coordinator = coordinator(store: store, session: session)
        let throttle = UpdateThrottle(store: store, interval: 6 * 3_600)
        let start = Date()

        await AutomaticUpdate.runIfDue(coordinator: coordinator, throttle: throttle, now: start)
        await AutomaticUpdate.runIfDue(coordinator: coordinator, throttle: throttle, now: start.addingTimeInterval(60))

        #expect(session.count == 2)
    }

    // MARK: What the user sees

    @Test("The sheet shows the same text for a rejected manifest as for a network failure")
    @MainActor
    func rejectionLooksLikeANetworkFailure() async throws {
        let rejected = UpdateProgressModel(stateProvider: FixedBlockerState(.enabled))
        await rejected.start(coordinator: coordinator(store: FilterStore.temporary(), session: unsignedSession()))
        let offline = UpdateProgressModel(stateProvider: FixedBlockerState(.enabled))
        let offlineSession = MockHTTPSession(responses: [endpoint: .failure(URLError(.notConnectedToInternet))])
        await offline.start(coordinator: coordinator(store: FilterStore.temporary(), session: offlineSession))

        #expect(rejected.phase == offline.phase)
        #expect(rejected.phase == .failed(String(localized: "updateprogress.status.failed")))
    }

    // MARK: Rollback on a fresh install

    // A fresh install has no cached manifest, so only the built-in minimum stops an old,
    // still validly signed manifest from replacing the bundled lists.
    @Test("A fresh install served an old, validly signed manifest keeps its bundled rules and reports a failed update")
    @MainActor
    func freshInstallRefusesAnOldSignedManifest() async throws {
        let store = FilterStore.temporary()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        _ = try await pipeline.installBundledSnapshotIfNeeded()
        let compiled = try await store.directoryURL(.compiled)
        let before = try FileManager.default.contentsOfDirectory(atPath: compiled.path).sorted().map {
            try Data(contentsOf: compiled.appendingPathComponent($0))
        }
        let installedBefore = try await store.read("installed_filters.json", in: .metadata)

        let minimum = BundledManifest.minimumVersion()
        let formatter = ISO8601DateFormatter()
        let old = FilterManifest(manifestVersion: formatter.string(from: minimum.addingTimeInterval(-1)), entries: [
            FilterManifest.Entry(
                id: "easylist", name: "EasyList", group: .ads,
                sourceURL: SignedManifests.sourceURL(endpoint, group: .ads, id: "easylist"),
                version: "2026-01-01", checksumSHA256: String(repeating: "0", count: 64), ruleCount: 1,
                enabledByDefault: true, premium: false
            )
        ])
        let session = SigningSession(MockHTTPSession(responses: [
            endpoint: .success((try JSONEncoder().encode(old), HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        ]))
        let coordinator = coordinator(
            store: store, pipeline: pipeline, session: session,
            verifier: SignedManifests.verifier(for: endpoint, minimum: minimum)
        )

        await #expect(throws: ManifestRejection.belowMinimum) { _ = try await coordinator.run() }
        let model = UpdateProgressModel(stateProvider: FixedBlockerState(.enabled))
        await model.start(coordinator: coordinator)

        #expect(model.phase == .failed(String(localized: "updateprogress.status.failed")))
        let after = try FileManager.default.contentsOfDirectory(atPath: compiled.path).sorted().map {
            try Data(contentsOf: compiled.appendingPathComponent($0))
        }
        #expect(after == before)
        #expect(try await store.read("installed_filters.json", in: .metadata) == installedBefore)
        #expect(try await ManifestStore(filterStore: store).load() == nil)
    }

    // MARK: Diagnostics

    @Test("The DEBUG log counts consecutive rejections by reason, and an accepted manifest resets it")
    func rejectionLogCountsConsecutiveRejections() async throws {
        let store = FilterStore.temporary()
        let log = ManifestRejectionLog()

        _ = try? await coordinator(store: store, session: unsignedSession(), rejectionLog: log).run()
        _ = try? await coordinator(store: store, session: unsignedSession(), rejectionLog: log).run()
        #expect(log.consecutive == 2)
        #expect(log.lastReason == .signature)

        let accepted = SigningSession(MockHTTPSession(responses: [
            endpoint: .success((
                try JSONEncoder().encode(FilterManifest(manifestVersion: SignedManifests.version, entries: [])),
                HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            ))
        ]))
        _ = try await coordinator(store: store, session: accepted, rejectionLog: log).run()
        #expect(log.consecutive == 0)
    }
}

private nonisolated struct FixedBlockerState {
    let value: ContentBlockerSettingsState
    init(_ value: ContentBlockerSettingsState) { self.value = value }
    func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState { value }
}

extension FixedBlockerState: ContentBlockerStateProviding {}

/// Counts requests, then answers from the wrapped session.
private final class CountingSession: @unchecked Sendable {
    private let wrapped: HTTPSession
    private let lock = NSLock()
    private var requests = 0
    var count: Int { lock.withLock { requests } }

    init(_ wrapped: HTTPSession) {
        self.wrapped = wrapped
    }
}

extension CountingSession: HTTPSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { requests += 1 }
        return try await wrapped.data(for: request)
    }
}
