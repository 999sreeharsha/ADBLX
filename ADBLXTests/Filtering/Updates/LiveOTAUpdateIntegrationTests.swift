// ADBLXTests/Filtering/Updates/LiveOTAUpdateIntegrationTests.swift
import Foundation
import Testing
@testable import ADBLX
import ADBLXShared

@Suite("Live OTA Update Integration Tests", .serialized)
struct LiveOTAUpdateIntegrationTests {
    private let store: FilterStore
    private let pipeline: FilterPipeline
    private let reloader: ReloadCoordinator
    private let manifestStore: ManifestStore
    private let extensionIdentifiers = AppCompositionRoot.extensionIdentifiers

    init() {
        let st = FilterStore.temporary()
        self.store = st
        self.reloader = ReloadCoordinator()
        self.pipeline = AppCompositionRoot.makeFilterPipeline(store: st)
        self.manifestStore = ManifestStore(filterStore: st)
    }

    /// The temporary store's root (the stand-in for the App Group container).
    private func containerURL() async throws -> URL {
        try await store.directoryURL(.compiled).deletingLastPathComponent()
    }

    @Test("Double Failure Rollback Integrity (Checksum Mismatch + WebKit DFA Rejection)")
    func doubleFailureRollbackIntegrity() async throws {
        let appGroupURL = try await containerURL()
        let previousDirURL = appGroupURL.appendingPathComponent("Previous")
        try await store.discardRollbackSnapshot()

        // -------------------------------------------------------------
        // STEP 1: Establish baseline on device disk
        // -------------------------------------------------------------
        _ = try await pipeline.installBundledSnapshotIfNeeded()
        let baselineAdsData = try Data(contentsOf: appGroupURL.appendingPathComponent("Compiled/Ads.json"))
        let baselineAdsRules = try JSONDecoder().decode([SafariContentBlockerRule].self, from: baselineAdsData)
        #expect(baselineAdsRules.count > 70_000, "Pre-condition: Baseline must have full production corpus")

        // -------------------------------------------------------------
        // STEP 2: Test Rollback on Failure Mode A (Checksum Mismatch)
        // -------------------------------------------------------------
        let corruptChecksumManifest = FilterManifest(
            manifestVersion: "2026-08-99-corrupt-sha",
            entries: [
                FilterManifest.Entry(
                    id: "corrupt-sha-entry",
                    name: "Corrupt SHA Filter",
                    group: .ads,
                    sourceURL: URL(string: "https://999sreeharsha.github.io/ADBLX/filters/ads/easylist.txt")!,
                    version: "2026-08-99",
                    checksumSHA256: "0000000000000000000000000000000000000000000000000000000000000000",
                    ruleCount: 100,
                    enabledByDefault: true,
                    premium: false
                )
            ]
        )

        let mockSessionA = MockHTTPSession(responses: [
            URL(string: "https://example.com/manifest-corrupt-sha.json")!: .success((
                try JSONEncoder().encode(corruptChecksumManifest),
                HTTPURLResponse(url: URL(string: "https://example.com/manifest-corrupt-sha.json")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )),
            URL(string: "https://999sreeharsha.github.io/ADBLX/filters/ads/easylist.txt")!: .success((
                Data("! Sample filter\n||example.com^".utf8),
                HTTPURLResponse(url: URL(string: "https://999sreeharsha.github.io/ADBLX/filters/ads/easylist.txt")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            ))
        ])

        let coordinatorA = UpdateCoordinator(
            manifestClient: ManifestClient(session: mockSessionA, endpoint: URL(string: "https://example.com/manifest-corrupt-sha.json")!),
            manifestStore: manifestStore,
            downloadClient: FilterDownloadClient(session: mockSessionA),
            pipeline: pipeline,
            store: store,
            reloader: reloader,
            extensionIdentifiers: extensionIdentifiers,
            entitlementService: StubEntitlementService(isPremiumEntitled: true)
        )

        do {
            _ = try await coordinatorA.run()
            Issue.record("Coordinator must throw on checksum mismatch")
        } catch {
            // Expected: Checksum.verify failed before any write to App Group
        }

        // Assert disk was untouched and Previous/ is absent
        let postAAdsData = try Data(contentsOf: appGroupURL.appendingPathComponent("Compiled/Ads.json"))
        let postAAdsRules = try JSONDecoder().decode([SafariContentBlockerRule].self, from: postAAdsData)
        #expect(postAAdsRules.count == baselineAdsRules.count, "Checksum failure must not modify Compiled/Ads.json")
        #expect(!FileManager.default.fileExists(atPath: previousDirURL.path), "Previous/ snapshot must be absent")

        // -------------------------------------------------------------
        // STEP 3: Test Rollback on Failure Mode B (Post-Snapshot WebKit DFA Gate Rejection)
        // -------------------------------------------------------------
        let malformedABPRule = """
        ! Title: Malformed List
        /(unclosed-group/
        """
        let malformedData = Data(malformedABPRule.utf8)
        let malformedChecksum = Checksum.sha256Hex(of: malformedData)

        let dfaRejectionManifest = FilterManifest(
            manifestVersion: "2026-08-99-dfa-reject",
            entries: [
                FilterManifest.Entry(
                    id: "dfa-reject-entry",
                    name: "DFA Rejection Filter",
                    group: .ads,
                    sourceURL: URL(string: "https://example.com/malformed.txt")!,
                    version: "2026-08-99",
                    checksumSHA256: malformedChecksum,
                    ruleCount: 1,
                    enabledByDefault: true,
                    premium: false
                )
            ]
        )

        let mockSessionB = MockHTTPSession(responses: [
            URL(string: "https://example.com/manifest-dfa-reject.json")!: .success((
                try JSONEncoder().encode(dfaRejectionManifest),
                HTTPURLResponse(url: URL(string: "https://example.com/manifest-dfa-reject.json")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )),
            URL(string: "https://example.com/malformed.txt")!: .success((
                malformedData,
                HTTPURLResponse(url: URL(string: "https://example.com/malformed.txt")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            ))
        ])

        let coordinatorB = UpdateCoordinator(
            manifestClient: ManifestClient(session: mockSessionB, endpoint: URL(string: "https://example.com/manifest-dfa-reject.json")!),
            manifestStore: manifestStore,
            downloadClient: FilterDownloadClient(session: mockSessionB),
            pipeline: pipeline,
            store: store,
            reloader: reloader,
            extensionIdentifiers: extensionIdentifiers,
            entitlementService: StubEntitlementService(isPremiumEntitled: true)
        )

        let runResultB = try await coordinatorB.run()
        switch runResultB {
        case .rolledBack(let reason):
            print("Successfully caught post-snapshot failure and rolled back: \(reason)")
        default:
            Issue.record("Expected .rolledBack result for malformed rule, got: \(runResultB)")
        }

        // Assert rollback integrity
        let rolledBackAdsData = try Data(contentsOf: appGroupURL.appendingPathComponent("Compiled/Ads.json"))
        let rolledBackAdsRules = try JSONDecoder().decode([SafariContentBlockerRule].self, from: rolledBackAdsData)
        #expect(rolledBackAdsRules.count == baselineAdsRules.count, "Rollback must restore original Compiled/Ads.json rule count")

        let rolledBackPrivacyData = try Data(contentsOf: appGroupURL.appendingPathComponent("Compiled/Privacy.json"))
        let rolledBackPrivacyRules = try JSONDecoder().decode([SafariContentBlockerRule].self, from: rolledBackPrivacyData)
        #expect(rolledBackPrivacyRules.count > 50_000, "Rollback must preserve intact Privacy ruleset (>50K)")

        #expect(!FileManager.default.fileExists(atPath: previousDirURL.path), "Previous/ snapshot must be cleaned up post-rollback")

        // Re-establish baseline clean state
        _ = try await pipeline.installBundledSnapshotIfNeeded()
    }

    @Test("Live CDN Remote Manifest Fetch and 304 Not Modified Caching")
    func liveCDNRemoteManifestFetchAnd304NotModifiedCaching() async throws {
        let liveManifestURL = URL(string: "https://999sreeharsha.github.io/ADBLX/manifest.json")!
        let manifestClient = ManifestClient(session: URLSession.shared, endpoint: liveManifestURL)
        let downloadClient = FilterDownloadClient(session: URLSession.shared)

        // 1. Fetch live manifest from CDN
        let fetchResult1 = try await manifestClient.fetch(previousETag: nil)
        guard case .updated(let manifest, let etag) = fetchResult1 else {
            Issue.record("First fetch from CDN must return updated with real manifest payload")
            return
        }

        #expect(!manifest.manifestVersion.isEmpty, "Manifest version must not be empty")
        #expect(manifest.entries.count >= 3, "Manifest must contain at least ads, privacy, and annoyances filters")
        #expect(etag != nil, "Fastly CDN response must provide an ETag header")
        print("Live CDN Fetch 1 Success: ETag=\(etag ?? "nil"), Entries=\(manifest.entries.count)")

        // 2. Fetch live manifest passing ETag to verify HTTP 304 Not Modified
        let fetchResult2 = try await manifestClient.fetch(previousETag: etag)
        guard case .notModified = fetchResult2 else {
            Issue.record("Second fetch with valid ETag must return .notModified (HTTP 304)")
            return
        }
        print("Live CDN Fetch 2 (Conditional 304 Not Modified) Success: Caching verified")

        // 3. Download live filter file directly over HTTPS and assert SHA-256 checksum
        guard let easylistEntry = manifest.entries.first(where: { $0.id == "easylist" }) else {
            Issue.record("Missing easylist entry")
            return
        }
        let downloadedFilter = try await downloadClient.download(easylistEntry)
        defer { try? FileManager.default.removeItem(at: downloadedFilter.tempFileURL) }

        let downloadedData = try Data(contentsOf: downloadedFilter.tempFileURL)
        let computedSHA = Checksum.sha256Hex(of: downloadedData)
        #expect(computedSHA == easylistEntry.checksumSHA256, "Live downloaded EasyList must match manifest SHA256 checksum")
        print("Live CDN Filter Download Success: Verified \(downloadedData.count) bytes matching SHA \(computedSHA)")
    }
}
