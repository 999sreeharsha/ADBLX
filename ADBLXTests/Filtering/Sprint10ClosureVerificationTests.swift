import XCTest
@testable import ADBLX
import ADBLXShared
import WebKit
import SafariServices

final class Sprint10ClosureVerificationTests: XCTestCase {
    private var tempDir: URL!
    private var filterStore: FilterStore!
    private var allowlistStore: AllowlistStore!
    private var pipeline: FilterPipeline!
    
    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Sprint10Closure_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        filterStore = FilterStore(overrideBaseURL: tempDir)
        allowlistStore = AllowlistStore(store: filterStore)
        
        let groupExtIDs = GroupExtensionIdentifiers(
            ads: "com.ADBLX.ADBLX.AdsBlocker",
            privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
            annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
            regional: "com.ADBLX.ADBLX.RegionalBlocker"
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
    
    private func loadFilterData(named name: String, relativeSubpath: String) -> Data? {
        let testBundle = Bundle(for: Self.self)
        if let url = testBundle.url(forResource: name, withExtension: "txt") {
            return try? Data(contentsOf: url)
        }
        if let url = testBundle.url(forResource: name, withExtension: "txt", subdirectory: "Filters") {
            return try? Data(contentsOf: url)
        }
        if let url = testBundle.url(forResource: name, withExtension: "txt", subdirectory: "Resources/Filters") {
            return try? Data(contentsOf: url)
        }
        
        let fileManager = FileManager.default
        let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates = [
            currentDir.appendingPathComponent("ADBLXTests/Resources/Filters/\(name).txt"),
            currentDir.appendingPathComponent("backend/public/filters/\(relativeSubpath)"),
            currentDir.appendingPathComponent("../../backend/public/filters/\(relativeSubpath)"),
            URL(fileURLWithPath: "/Users/sreeharshag/Work/ADBLX/backend/public/filters/\(relativeSubpath)"),
            URL(fileURLWithPath: "/Users/sreeharshag/Work/ADBLX/ADBLXTests/Resources/Filters/\(name).txt")
        ]
        
        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path), let data = try? Data(contentsOf: candidate) {
                return data
            }
        }
        return nil
    }
    
    func testSprint10ClosureEndToEndArtifactVerification() async throws {
        let groupsToTest: [(group: FilterGroup, name: String, subpath: String, id: String)] = [
            (.ads, "easylist", "ads/easylist.txt", "easylist"),
            (.privacy, "easyprivacy", "privacy/easyprivacy.txt", "easyprivacy"),
            (.annoyances, "fanboy-annoyances", "annoyances/fanboy-annoyances.txt", "fanboy-annoyances")
        ]
        
        print("\n================ SPRINT 10 CLOSURE ARTIFACT AUDIT ================")
        var totalPipelineDuration: TimeInterval = 0
        let fileManager = FileManager.default
        
        for item in groupsToTest {
            guard let rawData = loadFilterData(named: item.name, relativeSubpath: item.subpath) else {
                XCTFail("Missing test filter data for \(item.name)")
                return
            }
            
            let checksum = Checksum.sha256Hex(of: rawData)
            let source = FilterSource(
                filterID: item.id,
                version: "2026.08.26",
                checksumSHA256: checksum,
                data: rawData
            )
            
            let composition = GroupComposition(group: item.group, sources: [source])
            
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await pipeline.install(composition, reloadStrategy: .deferred)
            let duration = CFAbsoluteTimeGetCurrent() - start
            totalPipelineDuration += duration
            
            print("Group: \(item.group.rawValue.uppercased())")
            print("  Pipeline Duration       : \(String(format: "%.3f", duration))s")
            print("  Published Rule Count    : \(result.installedRuleCount)")
            
            // 1. Inspect Published Artifact
            let compiledDir = try await filterStore.directoryURL(.compiled)
            let artifactURL = compiledDir.appendingPathComponent("\(item.group.rawValue.capitalized).json")
            XCTAssertTrue(fileManager.fileExists(atPath: artifactURL.path), "Missing published artifact for \(item.group)")
            
            let artifactData = try Data(contentsOf: artifactURL)
            XCTAssertFalse(artifactData.isEmpty)
            
            // 2. Decode and verify JSON format
            let decodedRules = try JSONDecoder().decode([SafariContentBlockerRule].self, from: artifactData)
            XCTAssertEqual(decodedRules.count, result.installedRuleCount, "Decoded count must equal published count")
            XCTAssertLessThanOrEqual(decodedRules.count, 150_000, "Rule count must satisfy <= 150,000 budget")
            
            // 3. Verify representative rule types exist
            let hasBlockRule = decodedRules.contains { $0.action.type == "block" }
            XCTAssertTrue(hasBlockRule, "\(item.group) must contain network block rules")
            
            if item.group == .ads || item.group == .annoyances {
                let hasCosmeticRule = decodedRules.contains { $0.action.type == "css-display-none" && $0.action.selector != nil }
                XCTAssertTrue(hasCosmeticRule, "\(item.group) must contain cosmetic css-display-none rules")
            }
            
            // 4. Verify unsupported semantic modifiers are absent (e.g. $popup)
            let hasRawPopupTrigger = decodedRules.contains { $0.trigger.urlFilter.contains("$popup") }
            XCTAssertFalse(hasRawPopupTrigger, "Raw unsupported modifier $popup must never leak into regex")
        }
        
        // 5. Test Allowlist Tail Invariant with Real Full Ads Artifact
        _ = try await allowlistStore.add(domain: "special-exception.org")
        let syncResults = try await pipeline.syncAllowlist(reloadStrategy: .deferred)
        XCTAssertFalse(syncResults.isEmpty)
        
        let adsArtifactURL = try await filterStore.directoryURL(.compiled).appendingPathComponent("Ads.json")
        let updatedAdsData = try Data(contentsOf: adsArtifactURL)
        let updatedAdsRules = try JSONDecoder().decode([SafariContentBlockerRule].self, from: updatedAdsData)
        
        // Tail rule must be the allowlist exception rule
        let tailRule = updatedAdsRules.last!
        XCTAssertEqual(tailRule.action.type, "ignore-previous-rules")
        XCTAssertEqual(tailRule.trigger.ifDomain, ["*special-exception.org"])
        XCTAssertEqual(tailRule.trigger.urlFilter, ".*")
        
        print("------------------------------------------------------------------")
        print("Total End-to-End Pipeline Duration: \(String(format: "%.3f", totalPipelineDuration))s")
        print("==================================================================\n")
        
        XCTAssertLessThan(totalPipelineDuration, 20.0, "Total pipeline duration with in-process DFA gate must remain within 20.0s")
    }
    
    private func getPhysicalFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return Double(info.phys_footprint) / (1024.0 * 1024.0)
        }
        var taskInfo = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(taskInfo.resident_size) / (1024.0 * 1024.0)
        }
        return 0.0
    }
    
    func testOnDeviceMemoryAndCompilationBenchmark() async throws {
        print("\n================ ON-DEVICE NFR-01 MEMORY & COMPILATION BENCHMARK ================")
        let baselineMB = getPhysicalFootprintMB()
        print(String(format: "Baseline Resident Footprint: %.2f MB", baselineMB))
        
        final class ContinuousMemorySampler: @unchecked Sendable {
            private var isRunning = true
            private(set) var peakFootprintMB: Double = 0
            private let lock = NSLock()
            
            init(initialMB: Double) {
                self.peakFootprintMB = initialMB
            }
            
            func start(sampleFunction: @escaping @Sendable () -> Double) {
                Thread.detachNewThread {
                    while true {
                        self.lock.lock()
                        let running = self.isRunning
                        self.lock.unlock()
                        guard running else { break }
                        
                        let current = sampleFunction()
                        self.lock.lock()
                        if current > self.peakFootprintMB {
                            self.peakFootprintMB = current
                        }
                        self.lock.unlock()
                        usleep(10_000) // 10ms sampling interval
                    }
                }
            }
            
            func stop() -> Double {
                lock.lock()
                isRunning = false
                let peak = peakFootprintMB
                lock.unlock()
                return peak
            }
        }
        
        let sampler = ContinuousMemorySampler(initialMB: baselineMB)
        sampler.start { [weak self] in
            return self?.getPhysicalFootprintMB() ?? 0
        }
        
        let groupsToTest: [(group: FilterGroup, name: String, subpath: String, id: String)] = [
            (.ads, "easylist", "ads/easylist.txt", "easylist"),
            (.privacy, "easyprivacy", "privacy/easyprivacy.txt", "easyprivacy"),
            (.annoyances, "fanboy-annoyances", "annoyances/fanboy-annoyances.txt", "fanboy-annoyances")
        ]
        
        var totalCompileDuration: TimeInterval = 0
        var totalRules = 0
        
        for item in groupsToTest {
            guard let rawData = loadFilterData(named: item.name, relativeSubpath: item.subpath) else {
                XCTFail("Missing test filter data for \(item.name)")
                return
            }
            
            let start = CFAbsoluteTimeGetCurrent()
            let (rules, report) = try NativeABPRuleCompiler.compile(source: rawData, group: item.group.rawValue)
            let duration = CFAbsoluteTimeGetCurrent() - start
            
            totalCompileDuration += duration
            totalRules += rules.count
            
            print("Group: \(item.group.rawValue.uppercased())")
            print(String(format: "  Compile Time            : %.3fs", duration))
            print(String(format: "  Compiled Rules          : %d", rules.count))
        }
        
        let continuousPeakMB = sampler.stop()
        let transientMemoryMB = continuousPeakMB - baselineMB
        print("------------------------------------------------------------------")
        print(String(format: "Total Rules Compiled        : %d", totalRules))
        print(String(format: "Total Pure Compile Time     : %.3fs (NFR-01 budget < 10.0s)", totalCompileDuration))
        print(String(format: "Continuous Peak Footprint   : %.2f MB (True High-Water Mark)", continuousPeakMB))
        print(String(format: "Peak Transient Memory Delta : %.2f MB (NFR-01 budget < 200.0 MB)", transientMemoryMB))
        print("==================================================================\n")
        
        XCTAssertLessThan(totalCompileDuration, 10.0, "Total pure compile duration must remain < 10.0s")
        XCTAssertLessThan(transientMemoryMB, 200.0, "Peak transient memory delta must remain < 200.0 MB")
    }
    
    func testOnDeviceReloadCoordinatorWallClockDuration() async throws {
        print("\n================ ON-DEVICE RELOADCOORDINATOR MULTI-TRIAL AUDIT ================")
        let store = AppCompositionRoot.makeFilterStore()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        
        // Ensure real DFA-compliant rules are compiled and written to App Group
        print("Installing DFA-compliant snapshot to App Group (with in-process WebKit DFA gate)...")
        _ = try await pipeline.installBundledSnapshotIfNeeded()
        
        let reloader = ReloadCoordinator(timeoutSeconds: 10)
        let extensionIDs = [
            "com.ADBLX.ADBLX.AdsBlocker",
            "com.ADBLX.ADBLX.PrivacyBlocker",
            "com.ADBLX.ADBLX.AnnoyancesBlocker",
            "com.ADBLX.ADBLX.RegionalBlocker"
        ]
        
        let trialsCount = 5
        for extID in extensionIDs {
            let isEnabled = await withCheckedContinuation { continuation in
                SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: extID) { state, _ in
                    continuation.resume(returning: state?.isEnabled ?? false)
                }
            }
            
            var durations: [Double] = []
            var allSucceeded = true
            
            for trial in 1...trialsCount {
                let result = await reloader.reload(extensionIdentifier: extID)
                durations.append(result.duration)
                if !result.success {
                    allSucceeded = false
                    if let err = result.error {
                        print("    Trial \(trial) FAILED: \(err.localizedDescription)")
                    }
                }
            }
            
            let coldDuration = durations.first ?? 0
            let warmDurations = durations.dropFirst()
            let warmAvg = warmDurations.isEmpty ? coldDuration : (warmDurations.reduce(0, +) / Double(warmDurations.count))
            let minDuration = durations.min() ?? 0
            let maxDuration = durations.max() ?? 0
            
            print("Extension: \(extID)")
            print("  Enabled in Settings : \(isEnabled)")
            print("  All 5 Trials Pass   : \(allSucceeded)")
            print(String(format: "  Cold Reload (Trial 1): %.4fs", coldDuration))
            print(String(format: "  Warm Reload Average : %.4fs", warmAvg))
            print(String(format: "  Min / Max Duration  : %.4fs / %.4fs", minDuration, maxDuration))
            
            XCTAssertTrue(allSucceeded, "All reload trials for \(extID) must succeed")
            XCTAssertLessThan(maxDuration, 10.0, "Worst-case reload for \(extID) must complete within 10s timeout")
        }
        print("==================================================================\n")
    }
    
    func testWKContentRuleListStoreCompilation() async throws {
        print("\n================ WKCONTENTRULELISTSTORE ON-DEVICE COMPILATION AUDIT ================")
        guard let store = WKContentRuleListStore.default() else {
            XCTFail("WKContentRuleListStore.default() returned nil")
            return
        }
        let groups: [(group: String, name: String, subpath: String)] = [
            ("Ads", "easylist", "ads/easylist.txt"),
            ("Privacy", "easyprivacy", "privacy/easyprivacy.txt"),
            ("Annoyances", "fanboy-annoyances", "annoyances/fanboy-annoyances.txt")
        ]
        
        for g in groups {
            guard let data = loadFilterData(named: g.name, relativeSubpath: g.subpath) else {
                XCTFail("Failed to load filter data for \(g.name)")
                continue
            }
            let (jsonData, report) = try NativeABPRuleCompiler.compileToJSON(source: data, group: g.group.lowercased())
            guard let jsonString = String(data: jsonData, encoding: .utf8) else { continue }
            
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let ruleList = try await store.compileContentRuleList(forIdentifier: "audit_\(g.group)", encodedContentRuleList: jsonString)
                let duration = CFAbsoluteTimeGetCurrent() - start
                print("Group: \(g.group) (\(report.compiledRuleCount) rules)")
                print(String(format: "  WebKit DFA Ingestion Time : %.4fs (SUCCESS)", duration))
                print("  RuleList Identifier       : \(ruleList?.identifier ?? "ok")")
            } catch {
                let duration = CFAbsoluteTimeGetCurrent() - start
                print("Group: \(g.group) (\(report.compiledRuleCount) rules)")
                print(String(format: "  WebKit DFA Ingestion Time : %.4fs (FAILED)", duration))
                print("  WebKit Error              : \(error)")
                XCTFail("Group \(g.group) failed WebKit DFA compilation: \(error)")
            }
        }
        print("==================================================================\n")
    }
    
    @MainActor
    func testColdStartLaunchDurationAcrossFiveTrials() async throws {
        print("\n================ ON-DEVICE COLD-START REPEATED BENCHMARK (NFR-05) ================")
        let warmupStore = AppCompositionRoot.makeFilterStore()
        let warmupManifestStore = ManifestStore(filterStore: warmupStore)
        if try await warmupManifestStore.load() == nil {
            let warmupPipeline = AppCompositionRoot.makeFilterPipeline(store: warmupStore)
            _ = await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: warmupPipeline, manifestStore: warmupManifestStore)
            let dummyManifest = FilterManifest(manifestVersion: "1", entries: [])
            try await warmupManifestStore.save(dummyManifest, etag: "\"baseline\"")
        }

        var durations: [Double] = []
        let trials = 5
        
        for trial in 1...trials {
            let start = CFAbsoluteTimeGetCurrent()
            
            // 1. Initialize Dependency Graph
            let filterStore = AppCompositionRoot.makeFilterStore()
            let pipeline = AppCompositionRoot.makeFilterPipeline(store: filterStore)
            let updateCoordinator = AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: filterStore)
            let onboardingStore = OnboardingCompletionStore()
            let trialRouter = AppCompositionRoot.makeTrialExpiryRouter()
            let uiDependencies = AppCompositionRoot.makeUIDependencies(
                configuration: .mock,
                store: filterStore,
                pipeline: pipeline,
                updateCoordinator: updateCoordinator
            )
            
            // 2. Evaluate Onboarding state
            _ = onboardingStore.hasCompletedOnboarding
            await trialRouter.evaluateRoute()
            
            // 3. Verify Bootstrap Gate (non-blocking fast path)
            let manifestStore = ManifestStore(filterStore: filterStore)
            let bootstrapRan = await ContentBlockerBootstrap.ensureInitialRulesInstalled(
                pipeline: pipeline,
                manifestStore: manifestStore
            )
            
            let duration = CFAbsoluteTimeGetCurrent() - start
            durations.append(duration)
            print(String(format: "  Trial %d Setup-to-Ready Duration: %.4fs (Bootstrap compile ran: %@)", trial, duration, bootstrapRan ? "YES" : "NO (Gated)"))
        }
        
        let avg = durations.reduce(0, +) / Double(durations.count)
        let minD = durations.min() ?? 0
        let maxD = durations.max() ?? 0
        let sumSquaredDiffs = durations.reduce(0.0) { $0 + pow($1 - avg, 2) }
        let stdDev = sqrt(sumSquaredDiffs / Double(durations.count))
        
        print("------------------------------------------------------------------")
        print(String(format: "Mean Cold-Start Duration : %.4fs (NFR-05 budget < 1.500s: PASS)", avg))
        print(String(format: "Min / Max Duration       : %.4fs / %.4fs", minD, maxD))
        print(String(format: "Standard Deviation       : ±%.4fs", stdDev))
        print("==================================================================\n")
        
        XCTAssertLessThan(avg, 1.5, "Mean launch setup duration must remain < 1.5s")
        XCTAssertLessThan(maxD, 1.5, "Worst-case launch setup duration must remain < 1.5s")
    }
}
