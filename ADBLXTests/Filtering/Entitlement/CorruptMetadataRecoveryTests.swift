import Testing
import Foundation
@testable import ADBLX

/// A corrupt `installed_filters.json` must not stop reconciling for good, and must not cost a
/// user any rules if the recovery itself fails.
@Suite("Corrupt metadata recovery", .serialized)
struct CorruptMetadataRecoveryTests {
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )
    private let oneRule = Data("[{\"trigger\":{\"url-filter\":\"seeded\"},\"action\":{\"type\":\"block\"}}]".utf8)

    private struct Harness {
        let store: FilterStore
        let compiler: RecoveryTestCompiler
        let pipeline: FilterPipeline
        let reconciler: PremiumEntitlementReconciler
    }

    private func makeHarness(entitled: Bool) -> Harness {
        let store = FilterStore.temporary()
        let gate = FilterTransactionGate()
        let compiler = RecoveryTestCompiler()
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

    private func seed(_ h: Harness) async throws {
        for (id, group, premium) in [
            ("easylist", FilterGroup.ads, false),
            ("easyprivacy", FilterGroup.privacy, false),
            ("fanboy-annoyances", FilterGroup.annoyances, true),
        ] {
            _ = try await h.pipeline.install(GroupComposition(group: group, sources: [FilterSource(
                filterID: id, version: "v1", checksumSHA256: Checksum.sha256Hex(of: oneRule), data: oneRule, premium: premium
            )]), reloadStrategy: .deferred)
        }
    }

    private func truncateMetadata(_ h: Harness) async throws {
        let data = try await h.store.read("installed_filters.json", in: .metadata)
        try await h.store.writeMetadata(data.prefix(data.count / 2), filename: "installed_filters.json")
    }

    private func installedIDs(_ h: Harness) async throws -> Set<String> {
        let data = try await h.store.read("installed_filters.json", in: .metadata)
        return Set(try JSONDecoder().decode([InstalledFilter].self, from: data).map(\.id))
    }

    private func ruleCount(_ name: String, _ h: Harness) async throws -> Int {
        let data = try await h.store.read(name, in: .compiled)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [Any]).count
    }

    @Test("not entitled: truncated metadata restores the free lists and removes premium rules")
    func recoversNotEntitled() async throws {
        let h = makeHarness(entitled: false)
        try await seed(h)
        try await truncateMetadata(h)

        #expect(await h.reconciler.reconcile() == .recoveredMetadata)

        #expect(try await installedIDs(h) == ["easylist", "easyprivacy"])
        #expect(try await ruleCount("Ads.json", h) > 1)
        #expect(try await ruleCount("Privacy.json", h) > 1)
        #expect(try await ruleCount("Annoyances.json", h) == 0)
        #expect(await h.reconciler.reconcile() == .noChange)
    }

    @Test("entitled: truncated metadata restores the free and premium lists")
    func recoversEntitled() async throws {
        let h = makeHarness(entitled: true)
        try await seed(h)
        try await truncateMetadata(h)

        #expect(await h.reconciler.reconcile() == .recoveredMetadata)

        #expect(try await installedIDs(h) == ["easylist", "easyprivacy", "fanboy-annoyances", "shield-fixes"])
        #expect(try await ruleCount("Annoyances.json", h) > 1)
        #expect(await h.reconciler.reconcile() == .noChange)
    }

    // A 304 would otherwise leave the user on the bundled lists until the manifest next changes.
    @Test("recovery clears the cached ETag so the next update does a full fetch")
    func recoveryClearsETag() async throws {
        let h = makeHarness(entitled: false)
        try await seed(h)
        let manifestStore = ManifestStore(filterStore: h.store)
        try await manifestStore.save(FilterManifest(manifestVersion: "1", entries: []), etag: "\"v1\"")
        try await truncateMetadata(h)

        _ = await h.reconciler.reconcile()

        #expect(try await manifestStore.load()?.etag == nil)
    }

    // The file exists and may be fine: before first unlock, for example, a read just fails.
    @Test("a file that can't be read, rather than decoded, changes nothing")
    func readFailureIsNotCorruption() async throws {
        let h = makeHarness(entitled: false)
        try await seed(h)
        let url = try await h.store.directoryURL(.metadata).appendingPathComponent("installed_filters.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let compilesBefore = h.compiler.count

        #expect(await h.reconciler.reconcile() == .noChange)

        #expect(h.compiler.count == compilesBefore)
        #expect(try await ruleCount("Ads.json", h) == 1)
    }

    // Partial failure: Ads compiles and is written before Privacy throws.
    @Test("a recovery that fails part-way restores every group, and isn't retried until next launch")
    func failedRecoveryRollsBack() async throws {
        let h = makeHarness(entitled: false)
        try await seed(h)
        try await truncateMetadata(h)
        let adsBefore = try await h.store.read("Ads.json", in: .compiled)
        let annoyancesBefore = try await h.store.read("Annoyances.json", in: .compiled)
        let metadataBefore = try await h.store.read("installed_filters.json", in: .metadata)
        h.compiler.fail(.privacy)

        #expect(await h.reconciler.reconcile() == .noChange)

        #expect(try await h.store.read("Ads.json", in: .compiled) == adsBefore)
        #expect(try await h.store.read("Annoyances.json", in: .compiled) == annoyancesBefore)
        #expect(try await h.store.read("installed_filters.json", in: .metadata) == metadataBefore)

        let compilesAfterFirstAttempt = h.compiler.count
        #expect(await h.reconciler.reconcile() == .noChange)
        #expect(h.compiler.count == compilesAfterFirstAttempt)
    }
}

private nonisolated final class RecoveryTestCompiler: RuleCompiler, @unchecked Sendable {
    private let lock = NSLock()
    private var compiles = 0
    private var failing: Set<FilterGroup> = []

    var count: Int { lock.withLock { compiles } }
    func fail(_ group: FilterGroup) { lock.withLock { _ = failing.insert(group) } }

    func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
        let shouldFail = lock.withLock {
            compiles += 1
            return failing.contains(group)
        }
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        return try await NativeRuleCompilerAdapter().compile(source: source, group: group)
    }
}
