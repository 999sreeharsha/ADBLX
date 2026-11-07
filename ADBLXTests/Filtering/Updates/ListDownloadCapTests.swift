import Foundation
import Testing
@testable import ADBLX

/// A list over the cap fails the update before anything is written, like a checksum mismatch
/// (docs/superpowers/plans/2026-11-07-list-download-cap.md, decision 3).
@Suite("List download cap", .serialized)
struct ListDownloadCapTests {
    private let endpoint = URL(string: "https://example.com/adblx/manifest.json")!
    private let ids = AppCompositionRoot.extensionIdentifiers
    /// Unique, because the workspace folder is shared with every suite running in parallel.
    private static let listID = "cap-test-list"

    private func entry(_ body: Data) -> FilterManifest.Entry {
        FilterManifest.Entry(
            id: Self.listID, name: "Cap test list", group: .ads,
            sourceURL: SignedManifests.sourceURL(endpoint, group: .ads, id: Self.listID),
            version: "2026-11-07", checksumSHA256: Checksum.sha256Hex(of: body), ruleCount: 1,
            enabledByDefault: true, premium: false
        )
    }

    /// This suite's files in the shared workspace.
    private func workspaceFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FilterDownloadClient.workspaceDirectory.path)) ?? [])
            .filter { $0.hasPrefix("\(Self.listID)-") }
    }

    @Test("The cap is 8 MB, about four times the largest list")
    func capIsEightMegabytes() {
        #expect(FilterDownloadClient.maxListBytes == 8 * 1_024 * 1_024)
    }

    @Test("A list over the cap is refused with its ID, and no file is left for it")
    func overTheCapIsRefused() async throws {
        let body = Data(repeating: 0x61, count: 5_000)
        let entry = entry(body)
        let response = HTTPURLResponse(url: entry.sourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let client = FilterDownloadClient(session: MockHTTPSession(responses: [entry.sourceURL: .success((body, response))]), maxListBytes: 4_000)

        await #expect(throws: FilterDownloadClientError.tooLarge(filterID: Self.listID)) {
            _ = try await client.download(entry)
        }
        #expect(workspaceFiles().isEmpty)
    }

    @Test("A list within the cap is downloaded into the workspace")
    func withinTheCapIsDownloaded() async throws {
        let body = Data(repeating: 0x61, count: 3_000)
        let entry = entry(body)
        let response = HTTPURLResponse(url: entry.sourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let client = FilterDownloadClient(session: MockHTTPSession(responses: [entry.sourceURL: .success((body, response))]), maxListBytes: 4_000)

        let downloaded = try await client.download(entry)
        defer { try? FileManager.default.removeItem(at: downloaded.tempFileURL) }

        #expect(downloaded.tempFileURL.deletingLastPathComponent().standardizedFileURL == FilterDownloadClient.workspaceDirectory.standardizedFileURL)
        #expect(try Data(contentsOf: downloaded.tempFileURL) == body)
    }

    @Test("An over-cap list fails the update with rules, metadata, cached manifest and ETag unchanged, and the workspace empty")
    func overTheCapFailsTheUpdate() async throws {
        let store = FilterStore.temporary()
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator(), gate: FilterTransactionGate()
        )
        let installed = Data("[{\"trigger\":{\"url-filter\":\"old\"},\"action\":{\"type\":\"block\"}}]".utf8)
        _ = try await pipeline.install(
            GroupComposition(group: .ads, sources: [FilterSource(
                filterID: "easylist", version: "2026-11-01", checksumSHA256: Checksum.sha256Hex(of: installed), data: installed
            )]),
            reloadStrategy: .deferred
        )
        let manifestStore = ManifestStore(filterStore: store)
        try await manifestStore.save(FilterManifest(manifestVersion: "2026-11-06T00:00:00Z", entries: []), etag: "\"cached\"")
        let before = (
            rules: try await store.read("Ads.json", in: .compiled),
            installed: try await store.read("installed_filters.json", in: .metadata),
            manifest: try await store.read("manifest.json", in: .metadata)
        )

        let oversized = Data(repeating: 0x61, count: 5_000)
        let listEntry = entry(oversized)
        let manifest = FilterManifest(manifestVersion: SignedManifests.version, entries: [listEntry])
        let session = MockHTTPSession(responses: [
            endpoint: .success((try JSONEncoder().encode(manifest), HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"new\""])!)),
            listEntry.sourceURL: .success((oversized, HTTPURLResponse(url: listEntry.sourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        ])
        let coordinator = UpdateCoordinator(
            manifestClient: SignedManifests.signingClient(session: session, endpoint: endpoint),
            manifestStore: manifestStore,
            downloadClient: FilterDownloadClient(session: session, maxListBytes: 4_000),
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(), extensionIdentifiers: ids,
            entitlementService: StubEntitlementService(isPremiumEntitled: false), gate: FilterTransactionGate()
        )

        await #expect(throws: FilterDownloadClientError.tooLarge(filterID: Self.listID)) {
            _ = try await coordinator.run()
        }

        #expect(try await store.read("Ads.json", in: .compiled) == before.rules)
        #expect(try await store.read("installed_filters.json", in: .metadata) == before.installed)
        #expect(try await store.read("manifest.json", in: .metadata) == before.manifest)
        #expect(workspaceFiles().isEmpty)
    }
}
