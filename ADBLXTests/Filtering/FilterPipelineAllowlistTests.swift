import XCTest
@testable import ADBLX
import ADBLXShared

final class FilterPipelineAllowlistTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: FilterStore!
    private var allowlistStore: AllowlistStore!
    private var compositionService: JSONArrayCompositionService!
    private var partitioner: GroupPartitioner!
    private var pipeline: FilterPipeline!
    private var writer: AtomicRuleWriter!
    private var reloader: ReloadCoordinator!
    
    private let extensionIdentifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineAllowlistTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        store = FilterStore(overrideBaseURL: tempDirectory)
        allowlistStore = AllowlistStore(store: store)
        compositionService = JSONArrayCompositionService()
        partitioner = GroupPartitioner(extensionIdentifiers: extensionIdentifiers)
        writer = AtomicRuleWriter()
        reloader = ReloadCoordinator()
        
        pipeline = FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            compositionService: compositionService,
            partitioner: partitioner,
            store: store,
            writer: writer,
            reloader: reloader,
            allowlistStore: allowlistStore
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        store = nil
        allowlistStore = nil
        pipeline = nil
        super.tearDown()
    }

    func testCompositionServiceAppendsAllowlistExceptionsAtTail() throws {
        let baseRule: [String: Any] = [
            "trigger": ["url-filter": ".*adserver.*"],
            "action": ["type": "block"]
        ]
        let baseData = try JSONSerialization.data(withJSONObject: [baseRule], options: [.sortedKeys])
        let source = FilterSource(filterID: "base-ads", version: "1.0", checksumSHA256: "abc", data: baseData)
        
        let allowlistRules = SafariAllowlistCompiler.compile(domains: ["example.com"])
        let composed = try compositionService.compose([source], group: .ads, allowlistRules: allowlistRules)
        
        XCTAssertEqual(composed.ruleCount, 2)
        
        let jsonArray = try JSONSerialization.jsonObject(with: composed.data) as? [[String: Any]]
        XCTAssertNotNil(jsonArray)
        XCTAssertEqual(jsonArray?.count, 2)
        
        // Rule 0 is the blocking rule
        XCTAssertEqual(jsonArray?[0]["action"] as? [String: String], ["type": "block"])
        
        // Rule 1 is the trailing allowlist exception rule
        XCTAssertEqual(jsonArray?[1]["action"] as? [String: String], ["type": "ignore-previous-rules"])
        let trigger = jsonArray?[1]["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["if-domain"] as? [String], ["*example.com"])
    }

    func testAllowlistStoreNormalizesAndLoadsDomains() async throws {
        _ = try await allowlistStore.add(domain: "https://WWW.EXAMPLE.COM/path?query=1")
        _ = try await allowlistStore.add(domain: "news.ycombinator.com:8080")
        
        let domains = await allowlistStore.loadDomains()
        XCTAssertEqual(domains, ["www.example.com", "news.ycombinator.com"])
    }

    func testSyncAllowlistRecomposesInstalledGroupsWithExceptions() async throws {
        // 1. Install base rule in ads group
        let baseRule: [String: Any] = [
            "trigger": ["url-filter": ".*tracker.*"],
            "action": ["type": "block"]
        ]
        let baseData = try JSONSerialization.data(withJSONObject: [baseRule], options: [.sortedKeys])
        let source = FilterSource(
            filterID: "easylist",
            version: "2026.08.01",
            checksumSHA256: Checksum.sha256Hex(of: baseData),
            data: baseData
        )
        let composition = GroupComposition(group: .ads, sources: [source])
        _ = try await pipeline.install(composition, reloadStrategy: .deferred)
        
        // Verify initial compiled rule count is 1
        let initialCompiledURL = try await store.directoryURL(.compiled).appendingPathComponent("Ads.json")
        let initialData = try Data(contentsOf: initialCompiledURL)
        let initialRules = try JSONSerialization.jsonObject(with: initialData) as? [Any]
        XCTAssertEqual(initialRules?.count, 1)
        
        // 2. Add domain to allowlist
        _ = try await allowlistStore.add(domain: "nytimes.com")
        
        // 3. Sync allowlist through pipeline
        let results = try await pipeline.syncAllowlist(reloadStrategy: .deferred)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].compiledRuleCount, 2)
        XCTAssertEqual(results[0].installedRuleCount, 2)
        
        // 4. Verify updated compiled file contains trailing allowlist exception
        let updatedData = try Data(contentsOf: initialCompiledURL)
        let updatedRules = try JSONSerialization.jsonObject(with: updatedData) as? [[String: Any]]
        XCTAssertEqual(updatedRules?.count, 2)
        XCTAssertEqual(updatedRules?[1]["action"] as? [String: String], ["type": "ignore-previous-rules"])
    }
}
