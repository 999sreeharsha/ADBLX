import XCTest
@testable import ADBLX
import ADBLXShared

final class SettingsServiceAllowlistTransactionTests: XCTestCase {
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
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsTransactionTests_\(UUID().uuidString)")
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

    func testSuccessfulAddAndRemoveRecomposesAndUpdatesArtifacts() async throws {
        // Install base rule
        let baseRule: [String: Any] = [
            "trigger": ["url-filter": ".*ad.*"],
            "action": ["type": "block"]
        ]
        let baseData = try JSONSerialization.data(withJSONObject: [baseRule], options: [.sortedKeys])
        let source = FilterSource(
            filterID: "easylist",
            version: "1.0",
            checksumSHA256: Checksum.sha256Hex(of: baseData),
            data: baseData
        )
        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [source]), reloadStrategy: .deferred)
        
        let service = RealSettingsService(allowlistStore: allowlistStore, pipeline: pipeline)
        
        // Add entry via SettingsService
        await service.addAllowlistEntry(domain: "https://Example.COM/path")
        
        let snapshotAfterAdd = await service.fetchSnapshot()
        XCTAssertEqual(snapshotAfterAdd.allowlist.count, 1)
        XCTAssertEqual(snapshotAfterAdd.allowlist.first?.domain, "example.com")
        
        // Check compiled Ads.json has the exception rule
        let compiledURL = try await store.directoryURL(.compiled).appendingPathComponent("Ads.json")
        let compiledData = try Data(contentsOf: compiledURL)
        let compiledRules = try JSONSerialization.jsonObject(with: compiledData) as? [[String: Any]]
        XCTAssertEqual(compiledRules?.count, 2)
        XCTAssertEqual(compiledRules?[1]["action"] as? [String: String], ["type": "ignore-previous-rules"])
        
        // Remove entry via SettingsService
        let entryID = snapshotAfterAdd.allowlist[0].id
        await service.removeAllowlistEntry(id: entryID)
        
        let snapshotAfterRemove = await service.fetchSnapshot()
        XCTAssertTrue(snapshotAfterRemove.allowlist.isEmpty)
        
        // Check compiled Ads.json no longer has the exception rule
        let dataAfterRemove = try Data(contentsOf: compiledURL)
        let rulesAfterRemove = try JSONSerialization.jsonObject(with: dataAfterRemove) as? [[String: Any]]
        XCTAssertEqual(rulesAfterRemove?.count, 1)
    }

    func testRollbackOnPipelineFailurePreservesAllowlistState() async throws {
        // Pipeline with a partitioner that fails when budget > 1 rule
        struct TinyBudgetPartitioner: RulePartitioner {
            let extensionIdentifiers: GroupExtensionIdentifiers
            nonisolated func partition(_ ruleSet: CompiledRuleSet, group: FilterGroup) async throws -> PartitionedRules {
                if ruleSet.ruleCount > 1 {
                    throw RulePartitionerError.ruleBudgetExceeded(group: group, count: ruleSet.ruleCount, limit: 1)
                }
                return PartitionedRules(
                    extensionIdentifier: extensionIdentifiers[group],
                    group: group,
                    json: ruleSet.rawJSON,
                    ruleCount: ruleSet.ruleCount
                )
            }
        }
        
        let failingPipeline = FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            compositionService: compositionService,
            partitioner: TinyBudgetPartitioner(extensionIdentifiers: extensionIdentifiers),
            store: store,
            writer: writer,
            reloader: reloader,
            allowlistStore: allowlistStore
        )
        
        // Install base rule (1 rule, fits in budget of 1)
        let baseRule: [String: Any] = [
            "trigger": ["url-filter": ".*ad.*"],
            "action": ["type": "block"]
        ]
        let baseData = try JSONSerialization.data(withJSONObject: [baseRule], options: [.sortedKeys])
        let source = FilterSource(
            filterID: "easylist",
            version: "1.0",
            checksumSHA256: Checksum.sha256Hex(of: baseData),
            data: baseData
        )
        _ = try await failingPipeline.install(GroupComposition(group: .ads, sources: [source]), reloadStrategy: .deferred)
        
        let service = RealSettingsService(allowlistStore: allowlistStore, pipeline: failingPipeline)
        
        // Adding an allowlist entry will push ruleCount to 2 -> fails TinyBudgetPartitioner
        await service.addAllowlistEntry(domain: "example.com")
        
        // Transaction should be rolled back -> snapshot.allowlist is empty!
        let snapshot = await service.fetchSnapshot()
        XCTAssertTrue(snapshot.allowlist.isEmpty, "Allowlist entry must be rolled back on pipeline failure")
    }
}
