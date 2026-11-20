import Testing
import Foundation
@testable import ADBLX

/// Inside every transaction: writes, then the blockers marked pending, then the commit, then the
/// reload. A process killed at any point leaves either a `Previous/` that launch restores (and
/// then reloads every blocker), or a committed state that still records the reloads it owes.
@Suite("Transaction commit order and launch recovery", .serialized)
struct TransactionCommitOrderTests {
    private let manifestEndpoint = URL(string: "https://example.com/manifest.json")!
    private let filterURL = URL(string: "https://example.com/filters/ads/easylist.txt")!
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )
    private let oldRules = Data("[{\"trigger\":{\"url-filter\":\"old\"},\"action\":{\"type\":\"block\"}}]".utf8)
    private let newRules = Data("[{\"trigger\":{\"url-filter\":\"new\"},\"action\":{\"type\":\"block\"}}]".utf8)
    private let oldManifest = FilterManifest(manifestVersion: "2026-11-01T00:00:00Z", entries: [])

    // MARK: - Update transaction

    // The update reloads only after its commit, so the latest a kill can leave a Previous/ is with
    // the rules, the manifest and its ETag and the pending marks all written, and no reload yet.
    @Test("an update killed at its commit is undone at the next launch, which reloads every blocker")
    func updateKilledAtCommit() async throws {
        let base = Self.makeBase()
        let events = EventLog()
        let reached = Reached()
        let store = FilterStore(overrideBaseURL: base, transactionHook: { step in
            guard step == .beforeCommit else { return }
            events.append("commit")
            await reached.arrive()
            await Parked.forever()
        })
        try await seedOldState(in: store)
        let coordinator = try makeCoordinator(store: store, events: events)
        Task { _ = try await coordinator.run() }
        await reached.wait()
        let onDisk = FilterStore(overrideBaseURL: base)
        #expect(try await ManifestStore(filterStore: onDisk).load()?.etag == "\"v1\"", "precondition: the new ETag was written")
        #expect(events.entries == ["commit"], "nothing may be reloaded before the commit")

        let nextLaunch = FilterStore(overrideBaseURL: base)
        let relaunchReloads = EventLog()
        let restored = await LaunchRecovery.run(
            store: nextLaunch, reloader: reloader(events: relaunchReloads), extensionIdentifiers: ids,
            gate: FilterTransactionGate(), stateProvider: EnabledBlockers()
        )

        #expect(restored)
        #expect(try await nextLaunch.read("Ads.json", in: .compiled) == oldRules)
        let cached = try await ManifestStore(filterStore: nextLaunch).load()
        #expect(cached?.manifest.manifestVersion == oldManifest.manifestVersion)
        #expect(cached?.etag == "\"v0\"")
        #expect(Set(relaunchReloads.entries) == Set(FilterGroup.allCases.map { "reload \(ids[$0])" }))
        #expect(await PendingReloads(store: nextLaunch, stateProvider: EnabledBlockers()).identifiers().isEmpty)
    }

    @Test("an update killed after its commit keeps the update and still owes Safari the reload")
    func updateKilledAfterCommit() async throws {
        let base = Self.makeBase()
        let events = EventLog()
        let reached = Reached()
        let store = FilterStore(overrideBaseURL: base, transactionHook: { step in
            guard step == .afterCommit else { return }
            await reached.arrive()
            await Parked.forever()
        })
        try await seedOldState(in: store)
        let coordinator = try makeCoordinator(store: store, events: events)
        Task { _ = try await coordinator.run() }
        await reached.wait()

        let nextLaunch = FilterStore(overrideBaseURL: base)
        let restored = await LaunchRecovery.run(
            store: nextLaunch, reloader: reloader(events: EventLog()), extensionIdentifiers: ids,
            gate: FilterTransactionGate(), stateProvider: EnabledBlockers()
        )

        #expect(!restored)
        #expect(String(decoding: try await nextLaunch.read("Ads.json", in: .compiled), as: UTF8.self).contains("\"new\""))
        #expect(await PendingReloads(store: nextLaunch, stateProvider: EnabledBlockers()).identifiers() == [ids.ads])
    }

    @Test("a completed update reloads after committing and owes nothing")
    func updateReloadsAfterCommit() async throws {
        let events = EventLog()
        let store = FilterStore.temporary(transactionHook: { step in
            if step == .beforeCommit { events.append("commit") }
        })
        try await seedOldState(in: store)

        _ = try await makeCoordinator(store: store, events: events).run()

        #expect(events.entries == ["commit", "reload \(ids.ads)"])
        #expect(await PendingReloads(store: store, stateProvider: EnabledBlockers()).identifiers().isEmpty)
    }

    // MARK: - Pipeline transaction (allowlist sync, compiler recompile)

    @Test("an allowlist sync reloads only after its commit")
    func allowlistSyncReloadsAfterCommit() async throws {
        let events = EventLog()
        let store = FilterStore.temporary(transactionHook: { step in
            if step == .beforeCommit { events.append("commit") }
        })
        let pipeline = makePipeline(store: store, events: events)
        _ = try await pipeline.install(adsComposition(oldRules), reloadStrategy: .deferred)

        let results = try await pipeline.syncAllowlist(reloadStrategy: .immediate)

        #expect(events.entries == ["commit", "reload \(ids.ads)"])
        #expect(results.first?.reloadResults.map(\.extensionIdentifier) == [ids.ads])
        #expect(await PendingReloads(store: store, stateProvider: EnabledBlockers()).identifiers().isEmpty)
    }

    @Test("an allowlist sync killed after its commit still owes Safari the reload")
    func allowlistSyncKilledAfterCommit() async throws {
        let base = Self.makeBase()
        let reached = Reached()
        let armed = Armed()
        let store = FilterStore(overrideBaseURL: base, transactionHook: { step in
            guard step == .afterCommit, armed.isOn else { return }
            await reached.arrive()
            await Parked.forever()
        })
        let pipeline = makePipeline(store: store, events: EventLog())
        _ = try await pipeline.install(adsComposition(oldRules), reloadStrategy: .deferred)
        armed.isOn = true
        Task { _ = try await pipeline.syncAllowlist(reloadStrategy: .immediate) }
        await reached.wait()

        let nextLaunch = FilterStore(overrideBaseURL: base)
        #expect(await LaunchRecovery.run(
            store: nextLaunch, reloader: reloader(events: EventLog()), extensionIdentifiers: ids,
            gate: FilterTransactionGate(), stateProvider: EnabledBlockers()
        ) == false)
        #expect(await PendingReloads(store: nextLaunch, stateProvider: EnabledBlockers()).identifiers() == [ids.ads])
    }

    // MARK: - Launch order

    @Test("launch recovers an interrupted transaction before any other filter work")
    func recoveryRunsFirst() async {
        let events = EventLog()
        let sequence = LaunchSequence(
            recoverInterruptedTransaction: { events.append("recover") },
            bootstrap: { events.append("bootstrap") },
            reconcile: { events.append("reconcile") },
            recompile: { events.append("recompile") },
            update: { events.append("update"); return true },
            afterUpdate: { events.append("afterUpdate") }
        )

        await sequence.run()

        #expect(events.entries == ["recover", "bootstrap", "reconcile", "recompile", "update", "afterUpdate"])
    }

    // MARK: - Helpers

    private static func makeBase() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterStore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seedOldState(in store: FilterStore) async throws {
        let compiled = try await store.directoryURL(.compiled)
        try oldRules.write(to: compiled.appendingPathComponent("Ads.json"))
        try await ManifestStore(filterStore: store).save(oldManifest, etag: "\"v0\"")
    }

    private func adsComposition(_ rules: Data) -> GroupComposition {
        GroupComposition(group: .ads, sources: [
            FilterSource(filterID: "easylist", version: "1", checksumSHA256: Checksum.sha256Hex(of: rules), data: rules)
        ])
    }

    private func reloader(events: EventLog) -> ReloadCoordinator {
        ReloadCoordinator(timeoutSeconds: 3) { identifier, completion in
            events.append("reload \(identifier)")
            completion(nil)
        }
    }

    private func makePipeline(store: FilterStore, events: EventLog) -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: reloader(events: events),
            gate: FilterTransactionGate(), stateProvider: EnabledBlockers()
        )
    }

    private func makeCoordinator(store: FilterStore, events: EventLog) throws -> UpdateCoordinator {
        let entry = FilterManifest.Entry(
            id: "easylist", name: "EasyList", group: .ads, sourceURL: filterURL,
            version: "2", checksumSHA256: Checksum.sha256Hex(of: newRules), ruleCount: 1,
            enabledByDefault: true, premium: false
        )
        let manifest = try JSONEncoder().encode(FilterManifest(manifestVersion: SignedManifests.version, entries: [entry]))
        let session = MockHTTPSession(responses: [
            manifestEndpoint: .success((manifest, HTTPURLResponse(
                url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""]
            )!)),
            filterURL: .success((newRules, HTTPURLResponse(url: filterURL, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        ])
        let reloader = reloader(events: events)
        return UpdateCoordinator(
            manifestClient: SignedManifests.signingClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: makePipeline(store: store, events: events), store: store, reloader: reloader,
            extensionIdentifiers: ids, entitlementService: StubEntitlementService(isPremiumEntitled: false),
            gate: FilterTransactionGate(), stateProvider: EnabledBlockers()
        )
    }
}

private nonisolated final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ event: String) { lock.withLock { stored.append(event) } }
    var entries: [String] { lock.withLock { stored } }
}

private nonisolated final class Armed: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var isOn: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private nonisolated struct EnabledBlockers {
    func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState { .enabled }
}

extension EnabledBlockers: ContentBlockerStateProviding {}
