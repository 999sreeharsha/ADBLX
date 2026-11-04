// ADBLXTests/Filtering/Entitlement/PremiumEntitlementReconcilerTests.swift
import Testing
import Foundation
@testable import ADBLX

/// Compiler wrapper whose failures can be switched on per group, to exercise a batch that
/// fails after an earlier group has already been written (gotchas.md: partial-failure case).
private final class FailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var groups: Set<FilterGroup> = []
    func fail(_ group: FilterGroup) { lock.lock(); groups.insert(group); lock.unlock() }
    func shouldFail(_ group: FilterGroup) -> Bool { lock.lock(); defer { lock.unlock() }; return groups.contains(group) }
}

private struct SwitchableCompiler: RuleCompiler {
    let failures: FailureSwitch
    nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
        if failures.shouldFail(group) { throw RuleCompilerError.invalidSource }
        return try await PassthroughRuleCompiler().compile(source: source, group: group)
    }
}

@Suite("PremiumEntitlementReconciler", .serialized)
struct PremiumEntitlementReconcilerTests {
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    private func rules(_ marker: String) -> Data {
        Data("[{\"trigger\":{\"url-filter\":\"\(marker)\"},\"action\":{\"type\":\"block\"}}]".utf8)
    }

    private func source(_ id: String, _ marker: String, premium: Bool) -> FilterSource {
        let data = rules(marker)
        return FilterSource(filterID: id, version: "v1", checksumSHA256: Checksum.sha256Hex(of: data),
                            data: data, premium: premium)
    }

    private struct Harness {
        let store: FilterStore
        let pipeline: FilterPipeline
        let reconciler: PremiumEntitlementReconciler
        let entitlement: MockSubscriptionService
        let failures: FailureSwitch
        let temp: URL
    }

    private func makeHarness(
        state: EntitlementState,
        compiler: Bool = true
    ) -> Harness {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Reconciler_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let store = FilterStore(overrideBaseURL: temp)
        let failures = FailureSwitch()
        let pipeline = FilterPipeline(
            validator: FilterValidator(),
            compiler: compiler ? SwitchableCompiler(failures: failures) : NativeRuleCompilerAdapter(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let entitlement = MockSubscriptionService(state: state)
        let reconciler = PremiumEntitlementReconciler(
            store: store, pipeline: pipeline, manifestStore: ManifestStore(filterStore: store),
            reloader: ReloadCoordinator(), extensionIdentifiers: ids, entitlementService: entitlement
        )
        return Harness(store: store, pipeline: pipeline, reconciler: reconciler,
                       entitlement: entitlement, failures: failures, temp: temp)
    }

    private func compiled(_ h: Harness, _ name: String) async throws -> Data {
        try Data(contentsOf: try await h.store.directoryURL(.compiled).appendingPathComponent(name))
    }

    private func installedFilters(_ h: Harness) async throws -> [InstalledFilter] {
        try JSONDecoder().decode([InstalledFilter].self, from: try await h.store.read("installed_filters.json", in: .metadata))
    }

    /// Free Ads + premium Annoyances (Fanboy and SHIELD fixes, as in the bundle) + premium Regional.
    private func seed(_ h: Harness) async throws {
        _ = try await h.pipeline.install(GroupComposition(group: .ads, sources: [source("easylist", "ads", premium: false)]), reloadStrategy: .deferred)
        _ = try await h.pipeline.install(GroupComposition(group: .annoyances, sources: [
            source("fanboy-annoyances", "cookie", premium: true),
            source("shield-fixes", "fixes", premium: true),
        ]), reloadStrategy: .deferred)
        _ = try await h.pipeline.install(GroupComposition(group: .regional, sources: [source("regional-in", "india", premium: true)]), reloadStrategy: .deferred)
    }

    // MARK: Downgrade

    @Test("not entitled: premium filters in every group are removed, groups compile to [], free Ads is byte-identical")
    func downgradeRemovesPremiumAndKeepsFree() async throws {
        let h = makeHarness(state: .free)
        defer { try? FileManager.default.removeItem(at: h.temp) }
        try await seed(h)
        let adsBefore = try await compiled(h, "Ads.json")

        let outcome = await h.reconciler.reconcile()

        guard case .downgraded(let removed, let groups, let reloadFailures) = outcome else {
            Issue.record("expected .downgraded, got \(outcome)"); return
        }
        #expect(removed == 3)
        #expect(groups == [.annoyances, .regional])
        #expect(reloadFailures >= 0)
        #expect(try await compiled(h, "Annoyances.json") == Data("[]".utf8))
        #expect(try await compiled(h, "Regional.json") == Data("[]".utf8))
        #expect(try await compiled(h, "Ads.json") == adsBefore)
        #expect(try await installedFilters(h).map(\.id) == ["easylist"])
    }

    @Test("downgrade is idempotent: a second pass is .noChange")
    func downgradeIsIdempotent() async throws {
        let h = makeHarness(state: .free)
        defer { try? FileManager.default.removeItem(at: h.temp) }
        try await seed(h)
        _ = await h.reconciler.reconcile()
        #expect(await h.reconciler.reconcile() == .noChange)
    }

    @Test("entitled with premium installed is .noChange and leaves rules alone")
    func entitledWithPremiumInstalledIsNoChange() async throws {
        let h = makeHarness(state: .annual(expiresAt: Date().addingTimeInterval(86400)))
        defer { try? FileManager.default.removeItem(at: h.temp) }
        try await seed(h)
        let before = try await compiled(h, "Annoyances.json")
        #expect(await h.reconciler.reconcile() == .noChange)
        #expect(try await compiled(h, "Annoyances.json") == before)
    }

    @Test("every loss path downgrades: trial expiry, subscription lapse, refund of lifetime",
          arguments: [
            EntitlementState.trial(expiresAt: Date().addingTimeInterval(86400)),
            EntitlementState.monthly(expiresAt: Date().addingTimeInterval(86400)),
            EntitlementState.annual(expiresAt: Date().addingTimeInterval(86400)),
            EntitlementState.lifetime
          ])
    func everyLossPathDowngrades(from entitled: EntitlementState) async throws {
        let h = makeHarness(state: entitled)
        defer { try? FileManager.default.removeItem(at: h.temp) }
        try await seed(h)
        #expect(await h.reconciler.reconcile() == .noChange)

        h.entitlement.updateState(.free)   // expiry / lapse / revocation all surface as .free
        guard case .downgraded(let removed, _, _) = await h.reconciler.reconcile() else {
            Issue.record("expected .downgraded after losing \(entitled)"); return
        }
        #expect(removed == 3)
        #expect(try await compiled(h, "Annoyances.json") == Data("[]".utf8))
    }

    @Test("partial failure mid-batch rolls back everything, including the group already written")
    func partialFailureRollsBackWholeBatch() async throws {
        let h = makeHarness(state: .free)
        defer { try? FileManager.default.removeItem(at: h.temp) }
        try await seed(h)
        let annoyancesBefore = try await compiled(h, "Annoyances.json")
        let regionalBefore = try await compiled(h, "Regional.json")

        h.failures.fail(.regional)   // groups run in rawValue order: annoyances succeeds, regional throws
        let outcome = await h.reconciler.reconcile()

        #expect(outcome == .rolledBack)
        #expect(try await compiled(h, "Annoyances.json") == annoyancesBefore)
        #expect(try await compiled(h, "Regional.json") == regionalBefore)
        #expect(Set(try await installedFilters(h).map(\.id)) == ["easylist", "fanboy-annoyances", "shield-fixes", "regional-in"])
    }

    // MARK: Legacy record resolution

    @Test("legacy record (no premium flag) resolves from the bundled catalog and is removed")
    func legacyResolvedFromCatalog() async throws {
        let h = makeHarness(state: .free)
        defer { try? FileManager.default.removeItem(at: h.temp) }
        _ = try await h.pipeline.install(GroupComposition(group: .annoyances,
            sources: [source("fanboy-annoyances", "cookie", premium: false)]), reloadStrategy: .deferred)
        try await stripPremiumFlags(h)   // rewrite installed_filters.json the way a pre-flag build wrote it

        guard case .downgraded(let removed, _, _) = await h.reconciler.reconcile() else {
            Issue.record("expected .downgraded"); return
        }
        #expect(removed == 1)
        #expect(try await installedFilters(h).isEmpty)
    }

    @Test("legacy record resolves from the cached manifest first, and free legacy records stay")
    func legacyResolvedFromCachedManifest() async throws {
        let h = makeHarness(state: .free)
        defer { try? FileManager.default.removeItem(at: h.temp) }
        _ = try await h.pipeline.install(GroupComposition(group: .regional,
            sources: [source("regional-in", "india", premium: false)]), reloadStrategy: .deferred)
        _ = try await h.pipeline.install(GroupComposition(group: .ads,
            sources: [source("easylist", "ads", premium: false)]), reloadStrategy: .deferred)
        try await stripPremiumFlags(h)
        let url = URL(string: "https://example.com/x.txt")!
        let manifest = FilterManifest(manifestVersion: "1", entries: [
            .init(id: "regional-in", name: "R", group: .regional, sourceURL: url, version: "1",
                  checksumSHA256: "x", ruleCount: 1, enabledByDefault: true, premium: true),
            .init(id: "easylist", name: "E", group: .ads, sourceURL: url, version: "1",
                  checksumSHA256: "x", ruleCount: 1, enabledByDefault: true, premium: false)
        ])
        try await ManifestStore(filterStore: h.store).save(manifest, etag: "\"e\"")

        guard case .downgraded(let removed, let groups, _) = await h.reconciler.reconcile() else {
            Issue.record("expected .downgraded"); return
        }
        #expect(removed == 1)
        #expect(groups == [.regional])
        let remaining = try await installedFilters(h)
        #expect(remaining.map(\.id) == ["easylist"])
        #expect(remaining.first?.premium == false)   // resolved flag is persisted
    }

    @Test("refund while the app is open: the entitlement stream drives an immediate downgrade")
    func streamDrivenDowngrade() async throws {
        let h = makeHarness(state: .annual(expiresAt: Date().addingTimeInterval(86400)))
        defer { try? FileManager.default.removeItem(at: h.temp) }
        try await seed(h)
        await h.reconciler.startObserving()
        try await Task.sleep(nanoseconds: 100_000_000)   // let the initial (entitled) pass settle
        #expect(try await installedFilters(h).count == 4)

        h.entitlement.updateState(.free)                 // StoreKit reports the revocation

        var remaining = 4
        for _ in 0..<50 where remaining != 1 {
            try await Task.sleep(nanoseconds: 100_000_000)
            remaining = try await installedFilters(h).count
        }
        #expect(remaining == 1)
        await h.reconciler.stopObserving()
    }

    // MARK: Regain

    @Test("entitled with the default premium list missing reinstalls it from the bundle")
    func regainRestoresFromBundle() async throws {
        let h = makeHarness(state: .lifetime, compiler: false)
        defer { try? FileManager.default.removeItem(at: h.temp) }
        _ = try await h.pipeline.install(GroupComposition(group: .ads,
            sources: [source("easylist", "ads", premium: false)]), reloadStrategy: .deferred)

        guard case .restored(let installed) = await h.reconciler.reconcile() else {
            Issue.record("expected .restored"); return
        }
        #expect(installed == 1)
        let annoyances = try #require(try await installedFilters(h).first { $0.id == "fanboy-annoyances" })
        #expect(annoyances.premium == true)
        #expect(try await installedFilters(h).contains { $0.id == "shield-fixes" && $0.premium == true })
        #expect(try await compiled(h, "Annoyances.json").count > 2)
        #expect(await h.reconciler.reconcile() == .noChange)
    }

    @Test("regain with a cached manifest also clears the ETag so the next update does a full fetch")
    func regainInvalidatesEtag() async throws {
        let h = makeHarness(state: .lifetime, compiler: false)
        defer { try? FileManager.default.removeItem(at: h.temp) }
        let manifestStore = ManifestStore(filterStore: h.store)
        try await manifestStore.save(FilterManifest(manifestVersion: "1", entries: []), etag: "\"cached\"")

        _ = await h.reconciler.reconcile()

        #expect(try await manifestStore.load()?.etag == nil)
    }

    // MARK: Helpers

    private func stripPremiumFlags(_ h: Harness) async throws {
        let data = try await h.store.read("installed_filters.json", in: .metadata)
        var array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for index in array.indices { array[index].removeValue(forKey: "premium") }
        try await h.store.writeMetadata(try JSONSerialization.data(withJSONObject: array), filename: "installed_filters.json")
    }
}
