// ADBLXTests/Filtering/ExtensionRuntimeVerificationTests.swift
import XCTest
@testable import ADBLX
import ADBLXShared

@MainActor
final class ExtensionRuntimeVerificationTests: XCTestCase {
    private var store: FilterStore!
    private var pipeline: FilterPipeline!
    private var reloader: ReloadCoordinator!
    private let extensionIdentifiers = AppCompositionRoot.extensionIdentifiers

    override func setUp() async throws {
        try await super.setUp()
        store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        reloader = ReloadCoordinator()
        pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
    }

    private var reachableTestCompositions: [(FilterGroup, String, String)] {
        let adsRules = """
        ! Title: Reachable Test Ads
        */ads-pixel.png*
        """
        let privacyRules = """
        ! Title: Reachable Test Privacy
        */privacy-track.js*
        """
        let annoyancesRules = """
        ! Title: Reachable Test Annoyances
        ##.test-adblx-annoyance-banner
        """
        let regionalRules = """
        ! Title: Reachable Test Regional
        */regional-pixel.png*
        """

        return [
            (.ads, "test-ads", adsRules),
            (.privacy, "test-privacy", privacyRules),
            (.annoyances, "test-annoyances", annoyancesRules),
            (.regional, "test-regional", regionalRules)
        ]
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    func testAllFourExtensionsAppGroupRoundTripAndReload() async throws {
        try XCTSkipIf(
            Self.isSimulator,
            "Skipped: SafariServices' ContentBlockerLoader service is not available on the iOS Simulator, so " +
            "SFContentBlockerManager reloads cannot succeed. Run on a physical device."
        )
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else {
            XCTFail("App Group container unavailable")
            return
        }

        // 1. Install each reachable synthetic composition via the real FilterPipeline path
        for (group, filterID, content) in reachableTestCompositions {
            let source = FilterSource(
                filterID: filterID,
                version: "test-1.0",
                checksumSHA256: "test-sha",
                data: Data(content.utf8)
            )
            let composition = GroupComposition(group: group, sources: [source])
            
            let result = try await pipeline.install(composition, reloadStrategy: .immediate)
            XCTAssertEqual(result.group, group)
            XCTAssertGreaterThan(result.installedRuleCount, 0)
            
            let groupURL = containerURL.appendingPathComponent("Compiled/\(group.rawValue.capitalized).json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: groupURL.path))
            
            let data = try Data(contentsOf: groupURL)
            let decoded = try JSONDecoder().decode([SafariContentBlockerRule].self, from: data)
            XCTAssertEqual(decoded.count, result.installedRuleCount)
        }

        // 2. Execute ReloadCoordinator across all 4 extensions
        let ids = [
            extensionIdentifiers.ads,
            extensionIdentifiers.privacy,
            extensionIdentifiers.annoyances,
            extensionIdentifiers.regional
        ]
        let reloadResults = await reloader.reload(extensionIdentifiers: ids)
        XCTAssertEqual(reloadResults.count, 4)
        for result in reloadResults {
            XCTAssertTrue(result.success, "Extension \(result.extensionIdentifier) reload failed: \(String(describing: result.error))")
        }

        // 3. Forceful restoration of the clean production bundled baseline for an entitled
        // install (Annoyances is premium and is bundled-installed only when entitled).
        let restoreResults = try await pipeline.installBundledSnapshotIfNeeded(includePremium: true)
        XCTAssertFalse(restoreResults.isEmpty, "Restoration must install production bundled groups")

        // 4. Post-Restore Verification Assertions (confirming production corpus on disk)
        let adsData = try Data(contentsOf: containerURL.appendingPathComponent("Compiled/Ads.json"))
        let adsDecoded = try JSONDecoder().decode([SafariContentBlockerRule].self, from: adsData)
        XCTAssertGreaterThan(adsDecoded.count, 70_000, "Ads must be restored to full production corpus (>70K rules)")

        let privacyData = try Data(contentsOf: containerURL.appendingPathComponent("Compiled/Privacy.json"))
        let privacyDecoded = try JSONDecoder().decode([SafariContentBlockerRule].self, from: privacyData)
        XCTAssertGreaterThan(privacyDecoded.count, 50_000, "Privacy must be restored to full production corpus (>50K rules)")

        let annoyancesData = try Data(contentsOf: containerURL.appendingPathComponent("Compiled/Annoyances.json"))
        let annoyancesDecoded = try JSONDecoder().decode([SafariContentBlockerRule].self, from: annoyancesData)
        XCTAssertGreaterThan(annoyancesDecoded.count, 45_000, "Annoyances must be restored to full production corpus (>45K rules)")
    }

    func testDeployReachableSyntheticRulesForManualSafariVerification() async throws {
        for (group, filterID, content) in reachableTestCompositions {
            let source = FilterSource(
                filterID: filterID,
                version: "test-manual-1.0",
                checksumSHA256: "test-manual-sha",
                data: Data(content.utf8)
            )
            let composition = GroupComposition(group: group, sources: [source])
            _ = try await pipeline.install(composition, reloadStrategy: .immediate)
        }

        let ids = [
            extensionIdentifiers.ads,
            extensionIdentifiers.privacy,
            extensionIdentifiers.annoyances,
            extensionIdentifiers.regional
        ]
        _ = await reloader.reload(extensionIdentifiers: ids)
    }

    func testRestoreProductionBaselineAfterManualVerification() async throws {
        _ = try await pipeline.installBundledSnapshotIfNeeded()
    }
}
