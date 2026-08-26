import XCTest
@testable import ADBLX
import ADBLXShared

final class FilterPipelineNativeABPIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var filterStore: FilterStore!
    private var allowlistStore: AllowlistStore!
    private var pipeline: FilterPipeline!
    
    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FilterPipelineNativeABP_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        filterStore = FilterStore(overrideBaseURL: tempDir)
        allowlistStore = AllowlistStore(store: filterStore)
        
        let groupExtIDs = GroupExtensionIdentifiers(
            ads: "com.ADBLX.Ads",
            privacy: "com.ADBLX.Privacy",
            annoyances: "com.ADBLX.Annoyances",
            regional: "com.ADBLX.Regional"
        )
        
        pipeline = FilterPipeline(
            validator: FilterValidator(),
            compiler: NativeRuleCompilerAdapter(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtIDs),
            store: filterStore,
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator(),
            allowlistStore: allowlistStore
        )
    }
    
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testRealABPTextCompilesAndInstallsEndToEnd() async throws {
        let abpContent = """
        ! Title: Test ABP List
        [Adblock Plus 2.0]
        ||doubleclick.net^$third-party,script
        ||google-analytics.com^$image
        example.com##.ad-header
        @@||safe-site.com^$document
        ||popup-ad.com^$popup
        example.com##+js(set, ads, false)
        """
        
        let sourceData = Data(abpContent.utf8)
        let source = FilterSource(
            filterID: "easylist-test",
            version: "1.0.0",
            checksumSHA256: Checksum.sha256Hex(of: sourceData),
            data: sourceData
        )
        
        let composition = GroupComposition(group: .ads, sources: [source])
        let result = try await pipeline.install(composition, reloadStrategy: .deferred)
        
        // 4 rules compiled: doubleclick, google-analytics, example.com cosmetic, safe-site unblock
        XCTAssertEqual(result.compiledRuleCount, 4)
        XCTAssertEqual(result.installedRuleCount, 4)
        
        // Read published artifact from Compiled/Ads.json
        let compiledURL = try await filterStore.directoryURL(.compiled).appendingPathComponent("Ads.json")
        let publishedData = try Data(contentsOf: compiledURL)
        
        let decodedRules = try JSONDecoder().decode([SafariContentBlockerRule].self, from: publishedData)
        // Invariant: CompilationReport.compiledRuleCount == decoded rules count
        XCTAssertEqual(decodedRules.count, 4)
        
        // Verify $popup did not compile into a plain block rule for popup-ad.com
        let hasPopupBlock = decodedRules.contains { $0.trigger.urlFilter.contains("popup-ad\\.com") }
        XCTAssertFalse(hasPopupBlock, "$popup rule must be skipped to avoid over-blocking")
    }
    
    func testAllowlistSyncWithABPTextSourcesAppendsExceptionsAtTail() async throws {
        let abpContent = """
        ||ads.com^
        news.com##.sponsor
        """
        let sourceData = Data(abpContent.utf8)
        let source = FilterSource(
            filterID: "ads-main",
            version: "1.0",
            checksumSHA256: Checksum.sha256Hex(of: sourceData),
            data: sourceData
        )
        
        let composition = GroupComposition(group: .ads, sources: [source])
        _ = try await pipeline.install(composition, reloadStrategy: .deferred)
        
        // Add allowlist entry
        _ = try await allowlistStore.add(domain: "news.com")
        
        // Sync allowlist
        let syncResults = try await pipeline.syncAllowlist(reloadStrategy: .deferred)
        XCTAssertFalse(syncResults.isEmpty)
        
        let compiledURL = try await filterStore.directoryURL(.compiled).appendingPathComponent("Ads.json")
        let publishedData = try Data(contentsOf: compiledURL)
        let decodedRules = try JSONDecoder().decode([SafariContentBlockerRule].self, from: publishedData)
        
        // 2 base rules + 1 allowlist exception rule = 3 total rules
        XCTAssertEqual(decodedRules.count, 3)
        
        // Verify trailing rule is the allowlist exception rule
        let lastRule = decodedRules.last!
        XCTAssertEqual(lastRule.action.type, "ignore-previous-rules")
        XCTAssertEqual(lastRule.trigger.ifDomain, ["*news.com"])
    }
}
