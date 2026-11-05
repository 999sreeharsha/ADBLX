import Testing
import Foundation
@testable import ADBLX

/// `Compiled/<Group>.sources.json` records which sources built `Compiled/<Group>.json`, so a
/// reconcile can spot rules that `installed_filters.json` no longer accounts for without
/// decoding the rules themselves.
@Suite("Compiled sources sidecar", .serialized)
struct CompiledSourcesDriftTests {
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )
    private let oneRule = Data("[{\"trigger\":{\"url-filter\":\"x\"},\"action\":{\"type\":\"block\"}}]".utf8)

    private struct Harness {
        let store: FilterStore
        let compiler: CountingCompiler
        let pipeline: FilterPipeline
        let reconciler: PremiumEntitlementReconciler
    }

    private func makeHarness(entitled: Bool = false) -> Harness {
        let store = FilterStore.temporary()
        let gate = FilterTransactionGate()
        let compiler = CountingCompiler()
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: compiler,
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator(),
            allowlistStore: AllowlistStore(store: store), gate: gate
        )
        let reconciler = PremiumEntitlementReconciler(
            store: store, pipeline: pipeline, manifestStore: ManifestStore(filterStore: store),
            reloader: ReloadCoordinator(), extensionIdentifiers: ids,
            entitlementService: StubEntitlementService(isPremiumEntitled: entitled), gate: gate
        )
        return Harness(store: store, compiler: compiler, pipeline: pipeline, reconciler: reconciler)
    }

    private func install(_ filterID: String, group: FilterGroup, premium: Bool, in harness: Harness) async throws {
        _ = try await harness.pipeline.install(GroupComposition(group: group, sources: [FilterSource(
            filterID: filterID, version: "v1", checksumSHA256: Checksum.sha256Hex(of: oneRule), data: oneRule, premium: premium
        )]), reloadStrategy: .deferred)
    }

    private func sidecar(_ name: String, in store: FilterStore) async throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: try await store.read(name, in: .compiled)) as? [String: Any]
    }

    private func ruleCount(_ name: String, in store: FilterStore) async throws -> Int? {
        (try JSONSerialization.jsonObject(with: try await store.read(name, in: .compiled)) as? [Any])?.count
    }

    private func writeCompiled(_ text: String, _ name: String, in store: FilterStore) async throws {
        try Data(text.utf8).write(to: try await store.directoryURL(.compiled).appendingPathComponent(name))
    }

    @Test("an install records its sources, rule count and compiled hash")
    func installWritesSidecar() async throws {
        let h = makeHarness()
        try await install("easylist", group: .ads, premium: false, in: h)

        let written = try #require(try await sidecar("Ads.sources.json", in: h.store))
        #expect(written["sourceIDs"] as? [String] == ["easylist"])
        #expect(written["ruleCount"] as? Int == 1)
        let compiled = try await h.store.read("Ads.json", in: .compiled)
        #expect(written["compiledSHA256"] as? String == Checksum.sha256Hex(of: compiled))
    }

    @Test("a downgrade leaves a sidecar that lists no premium source")
    func downgradeRewritesSidecar() async throws {
        let h = makeHarness()
        try await install("fanboy-annoyances", group: .annoyances, premium: true, in: h)

        _ = await h.reconciler.reconcile()

        let written = try #require(try await sidecar("Annoyances.sources.json", in: h.store))
        #expect(written["sourceIDs"] as? [String] == [])
        #expect(written["ruleCount"] as? Int == 0)
    }

    @Test("rules from a source that is no longer installed are recompiled away")
    func staleSourceIsRepaired() async throws {
        let h = makeHarness()
        try await install("fanboy-annoyances", group: .annoyances, premium: true, in: h)
        _ = await h.reconciler.reconcile()
        // What the old race left behind: premium rules on disk, nothing in the metadata.
        try await writeCompiled(String(decoding: oneRule, as: UTF8.self), "Annoyances.json", in: h.store)
        try await writeCompiled("{\"sourceIDs\":[\"fanboy-annoyances\"],\"compiledSHA256\":\"x\",\"ruleCount\":1}", "Annoyances.sources.json", in: h.store)

        let outcome = await h.reconciler.reconcile()

        #expect(outcome == .repaired(groups: [.annoyances], reloadFailures: outcome.reloadFailuresForTesting))
        #expect(try await ruleCount("Annoyances.json", in: h.store) == 0)
        #expect(try await sidecar("Annoyances.sources.json", in: h.store)?["sourceIDs"] as? [String] == [])
    }

    @Test("a missing sidecar counts as drift for a group with installed sources")
    func missingSidecarIsRepaired() async throws {
        let h = makeHarness()
        try await install("easylist", group: .ads, premium: false, in: h)
        try await writeCompiled("[]", "Ads.json", in: h.store)
        try FileManager.default.removeItem(at: try await h.store.directoryURL(.compiled).appendingPathComponent("Ads.sources.json"))

        let outcome = await h.reconciler.reconcile()

        #expect(outcome == .repaired(groups: [.ads], reloadFailures: outcome.reloadFailuresForTesting))
        #expect(try await ruleCount("Ads.json", in: h.store) == 1)
        #expect(try await sidecar("Ads.sources.json", in: h.store)?["sourceIDs"] as? [String] == ["easylist"])
    }

    @Test("a matching sidecar recompiles nothing")
    func matchingSidecarIsNoChange() async throws {
        let h = makeHarness()
        try await install("easylist", group: .ads, premium: false, in: h)
        let compilesBefore = h.compiler.count

        #expect(await h.reconciler.reconcile() == .noChange)
        #expect(h.compiler.count == compilesBefore)
    }

    @Test("rules on disk for a group with no installed sources and no sidecar are emptied")
    func emptyGroupWithoutSidecarIsRepaired() async throws {
        let h = makeHarness()
        // What the old race left on an install that predates the sidecar.
        try await writeCompiled(String(decoding: oneRule, as: UTF8.self), "Annoyances.json", in: h.store)

        let outcome = await h.reconciler.reconcile()

        #expect(outcome == .repaired(groups: [.annoyances], reloadFailures: outcome.reloadFailuresForTesting))
        #expect(try await ruleCount("Annoyances.json", in: h.store) == 0)
        #expect(try await sidecar("Annoyances.sources.json", in: h.store)?["sourceIDs"] as? [String] == [])
    }

    @Test("a group already emptied is not recompiled on every launch")
    func emptiedGroupIsNoChange() async throws {
        let h = makeHarness()
        try await install("fanboy-annoyances", group: .annoyances, premium: true, in: h)
        _ = await h.reconciler.reconcile()
        let compilesBefore = h.compiler.count

        #expect(await h.reconciler.reconcile() == .noChange)
        #expect(h.compiler.count == compilesBefore)
    }

    @Test("a repaired empty group keeps its allowlist rules, and stays repaired")
    func emptyGroupKeepsAllowlistRules() async throws {
        let h = makeHarness()
        _ = try await AllowlistStore(store: h.store).add(domain: "example.com")
        try await writeCompiled(String(decoding: oneRule, as: UTF8.self), "Annoyances.json", in: h.store)

        _ = await h.reconciler.reconcile()

        let rules = try await h.store.read("Annoyances.json", in: .compiled)
        #expect(String(decoding: rules, as: UTF8.self).contains("example"))
        #expect(!String(decoding: rules, as: UTF8.self).contains("\"block\""))
        #expect(try await sidecar("Annoyances.sources.json", in: h.store)?["sourceIDs"] as? [String] == [])
        #expect(await h.reconciler.reconcile() == .noChange)
    }

    @Test("a group with no rules on disk needs no repair")
    func freshInstallIsNoChange() async {
        let h = makeHarness()

        #expect(await h.reconciler.reconcile() == .noChange)
        #expect(h.compiler.count == 0)
    }

    @Test("an unreadable installed_filters.json is not read as nothing installed")
    func corruptMetadataKeepsRules() async throws {
        let h = makeHarness()
        try await install("easylist", group: .ads, premium: false, in: h)
        try await h.store.writeMetadata(Data("{".utf8), filename: "installed_filters.json")

        #expect(await h.reconciler.reconcile() == .noChange)
        #expect(try await ruleCount("Ads.json", in: h.store) == 1)
    }

    @Test("the uninstalled bundled Ads fallback is not drift")
    func bundledFallbackIsNoChange() async throws {
        let h = makeHarness()
        // What syncAllowlist writes when nothing is installed: rules from the bundle, and no
        // installed_filters.json entry for them.
        try await writeCompiled(String(decoding: oneRule, as: UTF8.self), "Ads.json", in: h.store)
        try await writeCompiled("{\"sourceIDs\":[\"ads-bundled\"],\"compiledSHA256\":\"x\",\"ruleCount\":1}", "Ads.sources.json", in: h.store)

        #expect(await h.reconciler.reconcile() == .noChange)
        #expect(try await ruleCount("Ads.json", in: h.store) == 1)
    }
}

private extension ReconcileOutcome {
    /// Reload results depend on the simulator's extension state, which these tests don't control.
    var reloadFailuresForTesting: Int {
        if case .repaired(_, let failures) = self { return failures }
        return -1
    }
}

private nonisolated final class CountingCompiler: RuleCompiler, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }

    func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
        lock.lock(); value += 1; lock.unlock()
        return try await PassthroughRuleCompiler().compile(source: source, group: group)
    }
}
