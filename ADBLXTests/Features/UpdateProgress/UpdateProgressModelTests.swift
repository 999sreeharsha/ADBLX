// ADBLXTests/Features/UpdateProgress/UpdateProgressModelTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("UpdateProgressModel", .serialized)
struct UpdateProgressModelTests {
    private let manifestEndpoint = URL(string: "https://example.com/manifest.json")!
    private let groupExtensionIdentifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    @Test("starts in the idle phase")
    func startsIdle() {
        let model = UpdateProgressModel()
        #expect(model.phase == .idle)
    }

    @Test("progressDescription reflects the current phase")
    func progressDescriptionReflectsPhase() {
        let model = UpdateProgressModel()
        model.phase = .downloading
        #expect(model.progressDescription == "Downloading filter updates…")
    }

    @Test("start(coordinator:) reaches .complete for a real up-to-date result")
    func startReachesComplete() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))

        let manifest = FilterManifest(manifestVersion: "1", entries: [])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(
            url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""]
        )!
        let session = MockHTTPSession(responses: [manifestEndpoint: .success((manifestData, manifestResponse))])
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
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers,
            entitlementService: StubEntitlementService(isPremiumEntitled: false)
        )
        let model = UpdateProgressModel()

        await model.start(coordinator: coordinator)

        #expect(model.phase == .complete)
    }

    @Test("start(coordinator:) reaches .failed when the coordinator throws")
    func startReachesFailedOnThrow() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let session = MockHTTPSession(responses: [:])  // no registered response — throws UnregisteredURL
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
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers,
            entitlementService: StubEntitlementService(isPremiumEntitled: false)
        )
        let model = UpdateProgressModel()

        await model.start(coordinator: coordinator)

        guard case .failed = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
    }
}
