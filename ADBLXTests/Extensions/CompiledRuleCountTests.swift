import Testing
import Foundation
@testable import ADBLX

/// A content-blocker extension has about 6 MB of memory, so the count it logs must come from
/// the sidecar and never from decoding the rules.
@Suite("Compiled rule count label")
struct CompiledRuleCountTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RuleCount_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("reads the count from the sidecar without touching the rules")
    func usesSidecar() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Not JSON, and a different count: parsing the rules could not produce "7".
        let rules = directory.appendingPathComponent("Ads.json")
        try Data("not json".utf8).write(to: rules)
        try Data("{\"sourceIDs\":[\"easylist\"],\"compiledSHA256\":\"x\",\"ruleCount\":7}".utf8)
            .write(to: directory.appendingPathComponent("Ads.sources.json"))

        #expect(CompiledRuleCount.label(forRulesAt: rules) == "7")
    }

    @Test("a missing sidecar is unknown, with no fallback to parsing the rules")
    func missingSidecar() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rules = directory.appendingPathComponent("Ads.json")
        try Data("[{},{}]".utf8).write(to: rules)

        #expect(CompiledRuleCount.label(forRulesAt: rules) == "unknown")
    }

    @Test("an unreadable sidecar is unknown")
    func corruptSidecar() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rules = directory.appendingPathComponent("Ads.json")
        try Data("[{},{}]".utf8).write(to: rules)
        try Data("{".utf8).write(to: directory.appendingPathComponent("Ads.sources.json"))

        #expect(CompiledRuleCount.label(forRulesAt: rules) == "unknown")
    }
}
