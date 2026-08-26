import XCTest
@testable import ADBLXShared

final class CorpusBenchmarkTests: XCTestCase {
    func testBenchmarkRealFilterCorpus() throws {
        // Locate workspace filter files relative to test runner
        let fileManager = FileManager.default
        let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        
        let candidatePaths = [
            currentDir.appendingPathComponent("backend/public/filters"),
            currentDir.appendingPathComponent("../../backend/public/filters"),
            URL(fileURLWithPath: "/Users/sreeharshag/Work/ADBLX/backend/public/filters")
        ]
        
        var filtersDir: URL?
        for path in candidatePaths {
            if fileManager.fileExists(atPath: path.path) {
                filtersDir = path
                break
            }
        }
        
        guard let baseFiltersDir = filtersDir else {
            print("Skipping benchmark: backend/public/filters not found at candidate paths")
            return
        }
        
        let groups: [(name: String, path: String)] = [
            ("ads", "ads/easylist.txt"),
            ("privacy", "privacy/easyprivacy.txt"),
            ("annoyances", "annoyances/fanboy-annoyances.txt")
        ]
        
        print("\n================= CORPUS COMPILATION BENCHMARK =================")
        var totalDuration: TimeInterval = 0
        var totalLines = 0
        var totalCompiled = 0
        
        for group in groups {
            let fileURL = baseFiltersDir.appendingPathComponent(group.path)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                XCTFail("Missing filter file at \(fileURL.path)")
                continue
            }
            
            let data = try Data(contentsOf: fileURL)
            let start = CFAbsoluteTimeGetCurrent()
            let (rules, report) = try NativeABPRuleCompiler.compile(source: data, group: group.name)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            
            totalDuration += elapsed
            totalLines += report.totalLinesProcessed
            totalCompiled += rules.count
            
            print("Group: \(group.name.uppercased()) (\(group.path))")
            print("  Input LinesProcessed : \(report.totalLinesProcessed)")
            print("  Compiled Rules       : \(rules.count) (<= 150,000 budget: \(rules.count <= 150_000 ? "PASS" : "FAIL"))")
            print("  Comments/Headers     : \(report.commentsAndHeadersCount)")
            print("  Skipped (Unsupported): \(report.skippedRulesCount)")
            print("  Deferred (Scriptlets): \(report.deferredToWebExtensionCount)")
            print("  Badfilter Count      : \(report.badfilterCount)")
            print("  Compilation Time     : \(String(format: "%.3f", elapsed))s")
            
            // Assert <= 150,000 budget
            XCTAssertLessThanOrEqual(rules.count, 150_000, "Group \(group.name) exceeded 150,000 rule budget!")
        }
        
        print("-----------------------------------------------------------------")
        print("Total Lines Processed : \(totalLines)")
        print("Total Rules Compiled  : \(totalCompiled)")
        print("Total Compilation Time: \(String(format: "%.3f", totalDuration))s (Budget < 10.0s: \(totalDuration < 10.0 ? "PASS" : "FAIL"))")
        print("=================================================================\n")
        
        // Assert whole corpus (< 10s budget)
        XCTAssertLessThan(totalDuration, 10.0, "Corpus compilation exceeded 10.0s budget!")
    }
}
