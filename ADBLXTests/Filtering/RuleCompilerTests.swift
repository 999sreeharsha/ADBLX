// ADBLXTests/Filtering/RuleCompilerTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("PassthroughRuleCompiler")
struct PassthroughRuleCompilerTests {
    @Test("compiles a valid JSON array, counting rules")
    func compilesValidArray() async throws {
        let source = Data("[{\"a\":1},{\"a\":2},{\"a\":3}]".utf8)
        let compiler = PassthroughRuleCompiler()
        let result = try await compiler.compile(source: source, group: .ads)

        #expect(result.group == .ads)
        #expect(result.ruleCount == 3)
        #expect(result.rawJSON == source)
        #expect(result.statistics.rulesLoaded == 3)
        #expect(result.statistics.duplicatesRemoved == 0)
        #expect(result.statistics.unsupportedRuleCount == 0)
    }

    @Test("throws on empty source")
    func throwsOnEmpty() async {
        let compiler = PassthroughRuleCompiler()
        await #expect(throws: RuleCompilerError.self) {
            _ = try await compiler.compile(source: Data(), group: .ads)
        }
    }

    @Test("throws on invalid JSON")
    func throwsOnInvalidJSON() async {
        let compiler = PassthroughRuleCompiler()
        await #expect(throws: RuleCompilerError.self) {
            _ = try await compiler.compile(source: Data("not json".utf8), group: .ads)
        }
    }
}
