import Testing
import Foundation
@testable import ADBLX

/// A list's tier can change between manifests. Premium-ness comes from the verified cached
/// manifest; the flag stored at install time is only the fallback when no verified manifest
/// lists it. Drives real update runs (signed manifests) and the reconciler on one store.
@Suite("Premium tier change", .serialized)
struct PremiumTierChangeTests {
    private let endpoint = URL(string: "https://example.com/manifest.json")!
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )
    private let rules = Data("[{\"trigger\":{\"url-filter\":\"india\"},\"action\":{\"type\":\"block\"}}]".utf8)

    private func entry(premium: Bool) -> FilterManifest.Entry {
        .init(id: "regional-in", name: "India", group: .regional,
              sourceURL: SignedManifests.sourceURL(endpoint, group: .regional, id: "regional-in"),
              version: "1", checksumSHA256: Checksum.sha256Hex(of: rules), ruleCount: 1,
              enabledByDefault: true, premium: premium)
    }

    private func pipeline(_ store: FilterStore) -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
    }

    /// One update run against a signed manifest listing `regional-in` with the given tier.
    private func update(_ store: FilterStore, version: String, premium: Bool, entitled: Bool) async throws -> UpdateRunResult {
        let manifest = FilterManifest(manifestVersion: version, entries: [entry(premium: premium)])
        let listURL = entry(premium: premium).sourceURL
        var responses = SignedManifests.responses(manifest, at: endpoint, headers: ["ETag": "\"\(version)\""])
        responses[listURL] = .success((rules, HTTPURLResponse(url: listURL, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        let session = MockHTTPSession(responses: responses)
        return try await UpdateCoordinator(
            manifestClient: SignedManifests.client(session: session, endpoint: endpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline(store), store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: ids, entitlementService: StubEntitlementService(isPremiumEntitled: entitled),
            gate: FilterTransactionGate()
        ).run()
    }

    private func reconciler(_ store: FilterStore) -> PremiumEntitlementReconciler {
        PremiumEntitlementReconciler(
            store: store, pipeline: pipeline(store), manifestStore: ManifestStore(filterStore: store),
            reloader: ReloadCoordinator(), extensionIdentifiers: ids,
            entitlementService: MockSubscriptionService(state: .free), gate: FilterTransactionGate()
        )
    }

    /// Empty when nothing has been installed yet: the file is written by the first install.
    private func installed(_ store: FilterStore) async throws -> [InstalledFilter] {
        do {
            return try JSONDecoder().decode([InstalledFilter].self, from: try await store.read("installed_filters.json", in: .metadata))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    @Test("a list that becomes premium is removed for a non-entitled user at the next reconcile")
    func freeToPremiumIsRemovedAtReconcile() async throws {
        let store = FilterStore.temporary()
        _ = try await update(store, version: "2026-11-07T00:00:00Z", premium: false, entitled: false)
        #expect(try await installed(store).map(\.id) == ["regional-in"])

        // The next manifest marks the same list (same version, same checksum) premium.
        _ = try await update(store, version: "2026-11-08T00:00:00Z", premium: true, entitled: false)

        guard case .downgraded(let removed, let groups, _) = await reconciler(store).reconcile() else {
            Issue.record("expected .downgraded"); return
        }
        #expect(removed == 1)
        #expect(groups == [.regional])
        #expect(try await installed(store).isEmpty)
        #expect(try Data(contentsOf: try await store.directoryURL(.compiled).appendingPathComponent("Regional.json")) == Data("[]".utf8))
    }

    @Test("a list that becomes free is installed for a non-entitled user at the next update, and reconcile keeps it")
    func premiumToFreeIsInstalledAtUpdate() async throws {
        let store = FilterStore.temporary()
        _ = try await update(store, version: "2026-11-07T00:00:00Z", premium: true, entitled: false)
        #expect(try await installed(store).isEmpty)

        _ = try await update(store, version: "2026-11-08T00:00:00Z", premium: false, entitled: false)

        let records = try await installed(store)
        #expect(records.map(\.id) == ["regional-in"])
        #expect(records.first?.premium == false)
        #expect(await reconciler(store).reconcile() == .noChange)
        #expect(try await installed(store).map(\.id) == ["regional-in"])
    }

    @Test("a cached manifest that was never verified is not trusted: the stored premium flag decides")
    func unverifiedCacheFallsBackToStoredFlag() async throws {
        let store = FilterStore.temporary()
        _ = try await pipeline(store).install(GroupComposition(group: .regional, sources: [FilterSource(
            filterID: "regional-in", version: "1", checksumSHA256: Checksum.sha256Hex(of: rules), data: rules, premium: true
        )]), reloadStrategy: .deferred)
        // A cache from before signatures were checked, claiming the list is free.
        let cached = CachedManifest(
            manifest: FilterManifest(manifestVersion: "2026-11-07T00:00:00Z", entries: [entry(premium: false)]),
            etag: nil, signatureVerified: false
        )
        try await store.writeMetadata(try JSONEncoder().encode(cached), filename: "manifest.json")

        guard case .downgraded(let removed, _, _) = await reconciler(store).reconcile() else {
            Issue.record("expected .downgraded"); return
        }
        #expect(removed == 1)
        #expect(try await installed(store).isEmpty)
    }
}
