import Testing
import Foundation
@testable import ADBLX

@Suite("UpdateCoordinator", .serialized)
struct UpdateCoordinatorTests {
    private let manifestEndpoint = URL(string: "https://example.com/manifest.json")!
    private let filterSourceURL = URL(string: "https://example.com/easylist.txt")!
    private let adsExtensionIdentifier = "com.ADBLX.ADBLX.AdsBlocker"
    private let groupExtensionIdentifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    private func manifestEntry(checksum: String) -> FilterManifest.Entry {
        FilterManifest.Entry(
            id: "easylist", name: "EasyList", group: .ads, sourceURL: filterSourceURL,
            version: "2026-07-18", checksumSHA256: checksum, ruleCount: 1,
            enabledByDefault: true, premium: false
        )
    }

    private func filterSourceJSON() -> Data {
        Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
    }

    private func makeCoordinator(
        manifestResponse: (Data, URLResponse),
        filterResponse: (Data, URLResponse),
        pipeline: FilterPipeline,
        store: FilterStore
    ) -> UpdateCoordinator {
        let session = MockHTTPSession(responses: [
            manifestEndpoint: .success(manifestResponse),
            filterSourceURL: .success(filterResponse),
        ])
        return UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline,
            store: store,
            reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers
        )
    }

    @Test("304 short-circuits to .upToDate with no downloads or installs")
    func notModifiedShortCircuits() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let manifestStore = ManifestStore(filterStore: store)
        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: "irrelevant")])
        try await manifestStore.save(manifest, etag: "\"cached-etag\"")

        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 304, httpVersion: nil, headerFields: nil)!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (Data(), manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        let result = try await coordinator.run()

        guard case .upToDate = result else {
            Issue.record("expected .upToDate, got \(result)")
            return
        }
    }

    @Test("successful single-filter update installs, commits the manifest, and reloads once")
    func successfulUpdateInstallsAndReloadsOnce() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))

        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: Checksum.sha256Hex(of: filterSourceJSON()))])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(
            url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""]
        )!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (manifestData, manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        let result = try await coordinator.run()

        guard case .updated(let installedIDs, let reloadResults) = result else {
            Issue.record("expected .updated, got \(result)")
            return
        }
        #expect(installedIDs == ["easylist"])
        #expect(reloadResults.count == 1)
        #expect(reloadResults[0].extensionIdentifier == adsExtensionIdentifier)

        let cached = try await ManifestStore(filterStore: store).load()
        #expect(cached?.etag == "\"v1\"")

        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
    }

    @Test("checksum mismatch aborts before any write and leaves prior state untouched")
    func checksumMismatchAbortsBeforeWrite() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let compiledDir = try await store.directoryURL(.compiled)
        let compiledFile = compiledDir.appendingPathComponent("Ads.json")
        try Data("[\"prior\"]".utf8).write(to: compiledFile, options: .atomic)

        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: "wrong-checksum")])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (manifestData, manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        await #expect(throws: ChecksumError.self) {
            _ = try await coordinator.run()
        }

        #expect(try Data(contentsOf: compiledFile) == Data("[\"prior\"]".utf8))
        try? FileManager.default.removeItem(at: compiledFile)
    }

    @Test("install failure mid-batch rolls back to prior Compiled/ and Metadata/ state with exactly one reload")
    func installFailureRollsBackWithOneReload() async throws {
        struct AlwaysFailingCompiler: RuleCompiler {
            nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
                throw RuleCompilerError.invalidSource
            }
        }

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let compiledDir = try await store.directoryURL(.compiled)
        let metadataDir = try await store.directoryURL(.metadata)
        let compiledFile = compiledDir.appendingPathComponent("Ads.json")
        let metadataFile = metadataDir.appendingPathComponent("installed_filters.json")
        try Data("[\"prior-compiled\"]".utf8).write(to: compiledFile, options: .atomic)
        try Data("[]".utf8).write(to: metadataFile, options: .atomic)

        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: Checksum.sha256Hex(of: filterSourceJSON()))])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: AlwaysFailingCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (manifestData, manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        let result = try await coordinator.run()

        guard case .rolledBack = result else {
            Issue.record("expected .rolledBack, got \(result)")
            return
        }
        #expect(try Data(contentsOf: compiledFile) == Data("[\"prior-compiled\"]".utf8))
        #expect(try Data(contentsOf: metadataFile) == Data("[]".utf8))

        try? FileManager.default.removeItem(at: compiledFile)
        try? FileManager.default.removeItem(at: metadataFile)
    }

    @Test("a second run against an unchanged manifest converges to .upToDate via the planner, not just via 304")
    func secondRunConvergesToUpToDateViaPlanner() async throws {
        // Regression test for a gap found in ABORT review: if FilterPipeline.install
        // doesn't record the real manifest version (Task 7's `version:` parameter),
        // UpdatePlanner can never match installedVersion == entry.version, so this
        // filter would re-download and re-install on every run forever, even when the
        // manifest hasn't changed and the server never sends a 304. This test proves
        // convergence through the planner path, independent of ETag/304 behavior — the
        // mock manifest response is a 200 both times, not a 304.
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))

        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: Checksum.sha256Hex(of: filterSourceJSON()))])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (manifestData, manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        let firstResult = try await coordinator.run()
        guard case .updated = firstResult else {
            Issue.record("expected first run to be .updated, got \(firstResult)")
            return
        }

        let secondResult = try await coordinator.run()
        guard case .upToDate = secondResult else {
            Issue.record("expected second run to be .upToDate (planner should emit .keep, not .install), got \(secondResult)")
            return
        }

        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
    }

    @Test("restore failure during rollback surfaces .rollbackFailed with both errors, and does not throw")
    func restoreFailureDuringRollbackSurfacesRollbackFailed() async throws {
        final class FailingOnMetadataFileManager: FileManager {
            override func copyItem(at srcURL: URL, to dstURL: URL) throws {
                // Only fail copies into the LIVE Metadata/ directory (i.e. restore()'s
                // Metadata/ replacement), not copies into Previous/Metadata/ (which
                // snapshotForRollback() performs first, and which also matches
                // "/Metadata/" as a substring) — otherwise this throws during snapshot
                // creation, before run()'s guarded catch block around restore() is ever
                // reached, and the scenario this test exists for never gets exercised.
                if dstURL.path.contains("/Metadata/") && !dstURL.path.contains("/Previous/") {
                    throw NSError(domain: "test.restore-failure", code: 1)
                }
                try super.copyItem(at: srcURL, to: dstURL)
            }
        }

        struct AlwaysFailingCompiler: RuleCompiler {
            nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
                throw RuleCompilerError.invalidSource
            }
        }

        let failingFileManager = FailingOnMetadataFileManager()
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier, fileManager: failingFileManager)
        let compiledDir = try await store.directoryURL(.compiled)
        let metadataDir = try await store.directoryURL(.metadata)
        try Data("[\"prior-compiled\"]".utf8).write(to: compiledDir.appendingPathComponent("Ads.json"), options: .atomic)
        try Data("[]".utf8).write(to: metadataDir.appendingPathComponent("installed_filters.json"), options: .atomic)

        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: Checksum.sha256Hex(of: filterSourceJSON()))])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: AlwaysFailingCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (manifestData, manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        let result = try await coordinator.run()

        guard case .rollbackFailed = result else {
            Issue.record("expected .rollbackFailed, got \(result)")
            return
        }

        // Previous/ must still exist — restore() only deletes it after success,
        // so a failed restore leaves the snapshot recoverable.
        let previousExists = failingFileManager.fileExists(
            atPath: try await store.directoryURL(.compiled).deletingLastPathComponent()
                .appendingPathComponent("Previous").path
        )
        #expect(previousExists)

        try? FileManager.default.removeItem(at: compiledDir.appendingPathComponent("Ads.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
        try? FileManager.default.removeItem(at: try await store.directoryURL(.compiled).deletingLastPathComponent().appendingPathComponent("Previous"))
    }

    @Test("manifest spanning all four groups installs each group once and reloads each affected extension once")
    func manifestAcrossAllGroupsInstallsEachGroupOnce() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let compiledDir = try await store.directoryURL(.compiled)
        for filename in ["manifest.json", "installed_filters.json"] {
            try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent(filename))
        }
        for filename in ["Ads.json", "Privacy.json", "Annoyances.json", "Regional.json"] {
            try? FileManager.default.removeItem(at: compiledDir.appendingPathComponent(filename))
        }

        let privacyURL = URL(string: "https://example.com/easyprivacy.txt")!
        let annoyancesURL = URL(string: "https://example.com/fanboy-annoyances.txt")!
        let regionalURL = URL(string: "https://example.com/regional-fr.txt")!
        let ruleJSON = filterSourceJSON()

        let entries = [
            manifestEntry(checksum: Checksum.sha256Hex(of: ruleJSON)),
            FilterManifest.Entry(
                id: "easyprivacy", name: "EasyPrivacy", group: .privacy, sourceURL: privacyURL,
                version: "2026-07-19", checksumSHA256: Checksum.sha256Hex(of: ruleJSON), ruleCount: 1,
                enabledByDefault: true, premium: false
            ),
            FilterManifest.Entry(
                id: "fanboy-annoyances", name: "Fanboy Annoyances", group: .annoyances, sourceURL: annoyancesURL,
                version: "2026-07-19", checksumSHA256: Checksum.sha256Hex(of: ruleJSON), ruleCount: 1,
                enabledByDefault: true, premium: false
            ),
            FilterManifest.Entry(
                id: "regional-fr", name: "Regional FR", group: .regional, sourceURL: regionalURL,
                version: "2026-07-19", checksumSHA256: Checksum.sha256Hex(of: ruleJSON), ruleCount: 1,
                enabledByDefault: true, premium: false
            ),
        ]
        let manifest = FilterManifest(manifestVersion: "1", entries: entries)
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let okResponse = { (url: URL) in HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)! }

        let session = MockHTTPSession(responses: [
            manifestEndpoint: .success((manifestData, manifestResponse)),
            filterSourceURL: .success((ruleJSON, okResponse(filterSourceURL))),
            privacyURL: .success((ruleJSON, okResponse(privacyURL))),
            annoyancesURL: .success((ruleJSON, okResponse(annoyancesURL))),
            regionalURL: .success((ruleJSON, okResponse(regionalURL))),
        ])
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline,
            store: store,
            reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers
        )

        let result = try await coordinator.run()

        guard case .updated(let installedIDs, let reloadResults) = result else {
            Issue.record("expected .updated, got \(result)")
            return
        }
        #expect(Set(installedIDs) == ["easylist", "easyprivacy", "fanboy-annoyances", "regional-fr"])
        // Ordered, hardcoded-literal comparison — not a Set, and not built from the
        // `groupExtensionIdentifiers` constant used to construct the SUT above. A Set
        // comparison (or reusing the same constant on both sides) cannot catch a
        // transposed group→identifier mapping: e.g. if `annoyances` and `regional`'s
        // strings were swapped in `GroupExtensionIdentifiers`, all four identifiers would
        // still appear, and an assertion built from the same swapped constant would agree
        // with itself. `UpdateCoordinator.run()` builds `affectedExtensionIDs` via
        // `installGroups.map { extensionIdentifiers[$0.group] }`, and `installGroups`
        // preserves manifest order (Ads, Privacy, Annoyances, Regional — see the `entries`
        // array above), so `reloadResults` — which `ReloadCoordinator.reload(extensionIdentifiers:)`
        // produces in the same order it's given — must match this exact sequence.
        #expect(reloadResults.map(\.extensionIdentifier) == [
            "com.ADBLX.ADBLX.AdsBlocker",
            "com.ADBLX.ADBLX.PrivacyBlocker",
            "com.ADBLX.ADBLX.AnnoyancesBlocker",
            "com.ADBLX.ADBLX.RegionalBlocker",
        ])

        for filename in ["Ads.json", "Privacy.json", "Annoyances.json", "Regional.json"] {
            #expect(FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent(filename).path))
        }

        for filename in ["manifest.json", "installed_filters.json"] {
            try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent(filename))
        }
        for filename in ["Ads.json", "Privacy.json", "Annoyances.json", "Regional.json"] {
            try? FileManager.default.removeItem(at: compiledDir.appendingPathComponent(filename))
        }
    }

    @Test("failure in one group of a multi-group batch rolls back every group's writes, with a reload planned for every originally-affected group")
    func multiGroupPartialFailureRollsBackEntireBatch() async throws {
        // Fails compilation only for .annoyances — Ads and Privacy (earlier in
        // UpdateCoordinator's per-group loop, per manifest order) must succeed and write
        // real content BEFORE Annoyances throws, so this proves rollback undoes every
        // group's writes in the batch, not just the one that failed. Sprint 2's inherited
        // rollback test only ever had one group to fail — this is the first test of
        // Sprint 3A's actual new failure surface: a partial failure partway through a
        // multi-group batch.
        struct FailsForGroupCompiler: RuleCompiler {
            let failingGroup: FilterGroup
            nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
                guard group != failingGroup else { throw RuleCompilerError.invalidSource }
                return try await PassthroughRuleCompiler().compile(source: source, group: group)
            }
        }

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let compiledDir = try await store.directoryURL(.compiled)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))

        let priorAds = Data("[\"prior-ads\"]".utf8)
        let priorPrivacy = Data("[\"prior-privacy\"]".utf8)
        try priorAds.write(to: compiledDir.appendingPathComponent("Ads.json"), options: .atomic)
        try priorPrivacy.write(to: compiledDir.appendingPathComponent("Privacy.json"), options: .atomic)
        try Data("[]".utf8).write(to: metadataDir.appendingPathComponent("installed_filters.json"), options: .atomic)

        let privacyURL = URL(string: "https://example.com/easyprivacy-partial.txt")!
        let annoyancesURL = URL(string: "https://example.com/fanboy-annoyances-partial.txt")!
        let ruleJSON = filterSourceJSON()

        let entries = [
            manifestEntry(checksum: Checksum.sha256Hex(of: ruleJSON)),
            FilterManifest.Entry(
                id: "easyprivacy", name: "EasyPrivacy", group: .privacy, sourceURL: privacyURL,
                version: "2026-07-19", checksumSHA256: Checksum.sha256Hex(of: ruleJSON), ruleCount: 1,
                enabledByDefault: true, premium: false
            ),
            FilterManifest.Entry(
                id: "fanboy-annoyances", name: "Fanboy Annoyances", group: .annoyances, sourceURL: annoyancesURL,
                version: "2026-07-19", checksumSHA256: Checksum.sha256Hex(of: ruleJSON), ruleCount: 1,
                enabledByDefault: true, premium: false
            ),
        ]
        let manifest = FilterManifest(manifestVersion: "1", entries: entries)
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let okResponse = { (url: URL) in HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)! }

        let session = MockHTTPSession(responses: [
            manifestEndpoint: .success((manifestData, manifestResponse)),
            filterSourceURL: .success((ruleJSON, okResponse(filterSourceURL))),
            privacyURL: .success((ruleJSON, okResponse(privacyURL))),
            annoyancesURL: .success((ruleJSON, okResponse(annoyancesURL))),
        ])
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: FailsForGroupCompiler(failingGroup: .annoyances),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline,
            store: store,
            reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers
        )

        let result = try await coordinator.run()

        guard case .rolledBack = result else {
            Issue.record("expected .rolledBack, got \(result)")
            return
        }

        // Ads and Privacy both installed successfully (writing real compiled content)
        // before Annoyances threw — rollback must restore ALL THREE to their prior
        // state, not just undo the group that failed.
        #expect(try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json")) == priorAds)
        #expect(try Data(contentsOf: compiledDir.appendingPathComponent("Privacy.json")) == priorPrivacy)
        let installedFiltersData = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        #expect(installedFiltersData == Data("[]".utf8))

        try? FileManager.default.removeItem(at: compiledDir.appendingPathComponent("Ads.json"))
        try? FileManager.default.removeItem(at: compiledDir.appendingPathComponent("Privacy.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
    }
}
