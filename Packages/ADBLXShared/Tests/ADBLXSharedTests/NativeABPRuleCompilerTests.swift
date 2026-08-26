import XCTest
@testable import ADBLXShared

final class NativeABPRuleCompilerTests: XCTestCase {
    func testCompileSampleABPText() throws {
        let sample = """
        ! Title: Sample List
        ! Checksum: 12345
        [Adblock Plus 2.0]
        ||doubleclick.net^$third-party
        ||google-analytics.com^$script
        example.com##.ad-box
        @@||safe-site.com^$document
        ||popup-domain.com^$popup
        example.com##+js(set, ads, false)
        ||broken-badfilter.com^
        ||broken-badfilter.com^$badfilter
        """
        
        let data = Data(sample.utf8)
        let (rules, report) = try NativeABPRuleCompiler.compile(source: data, group: "ads")
        
        // 4 rules should be compiled: doubleclick, google-analytics, example.com cosmetic, safe-site unblock
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(report.compiledRuleCount, 4)
        XCTAssertEqual(report.commentsAndHeadersCount, 3)
        XCTAssertEqual(report.deferredToWebExtensionCount, 1) // scriptlet
        XCTAssertEqual(report.badfilterCount, 1)              // badfilter
        XCTAssertEqual(report.unsupportedSemanticModifiers["popup"], 1)
        XCTAssertEqual(report.group, "ads")
        XCTAssertGreaterThan(report.compilationDurationSeconds, 0)
    }
    
    func testCompileToJSONProducesValidUTF8() throws {
        let sample = """
        ||ads.com^
        news.com##.sponsor
        """
        let data = Data(sample.utf8)
        let (jsonData, report) = try NativeABPRuleCompiler.compileToJSON(source: data, group: "ads")
        
        XCTAssertEqual(report.compiledRuleCount, 2)
        XCTAssertFalse(jsonData.isEmpty)
        
        // Verify JSON is valid Safari Content Blocker JSON array
        let decoded = try JSONDecoder().decode([SafariContentBlockerRule].self, from: jsonData)
        XCTAssertEqual(decoded.count, 2)
    }
    
    func testBadfilterRetractsTargetRule() throws {
        let sample = """
        ||good-domain.com^$script
        ||broken-domain.com^$script
        ||another-domain.com^
        ||broken-domain.com^$script,badfilter
        """
        let data = Data(sample.utf8)
        let (rules, report) = try NativeABPRuleCompiler.compile(source: data, group: "ads")
        
        // ||broken-domain.com^$script should be retracted by ||broken-domain.com^$script,badfilter
        // Only good-domain and another-domain should be compiled
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(report.compiledRuleCount, 2)
        XCTAssertEqual(report.badfilterCount, 1)
        
        // Assert that broken-domain is NOT in the compiled rules
        let containsBroken = rules.contains { rule in
            rule.trigger.urlFilter.contains("broken-domain")
        }
        XCTAssertFalse(containsBroken, "Retracted rule must not be compiled into Safari Content Blocker rules")
    }
    
    func testBadfilterDoesNotRetractDistinctOrDifferentOptionRules() throws {
        let sample = """
        ||domain.com/ad.js$image
        ||domain.com/ad.js$script
        ||domain.com/other$image
        ||domain.com/ad.js$image,third-party
        ||domain.com/ad.js$image,badfilter
        """
        let data = Data(sample.utf8)
        let (rules, report) = try NativeABPRuleCompiler.compile(source: data, group: "ads")
        
        // Only ||domain.com/ad.js$image should be retracted by ||domain.com/ad.js$image,badfilter
        // The other 3 rules (script, other, and third-party) MUST NOT be falsely retracted
        XCTAssertEqual(report.badfilterCount, 1)
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(report.compiledRuleCount, 3)
        
        // Confirm script rule survived
        let hasScript = rules.contains { $0.trigger.resourceType?.contains("script") ?? false }
        XCTAssertTrue(hasScript, "Rule with different resource type must not be retracted")
        
        // Confirm other path survived
        let hasOther = rules.contains { $0.trigger.urlFilter.contains("other") }
        XCTAssertTrue(hasOther, "Rule with different URL pattern must not be retracted")
        
        // Confirm third-party option rule survived
        let hasThirdParty = rules.contains { $0.trigger.loadType?.contains("third-party") ?? false }
        XCTAssertTrue(hasThirdParty, "Rule with additional modifiers must not be retracted")
    }
    
    func testBadfilterRetractsWithPermutedDomainOptionSubOrder() throws {
        let sample = """
        ||tracker.com^$domain=b.com|a.com
        ||tracker.com^$domain=a.com|b.com,badfilter
        """
        let data = Data(sample.utf8)
        let (rules, report) = try NativeABPRuleCompiler.compile(source: data, group: "ads")
        
        // Permuted domain sub-orders must match and retract the rule
        XCTAssertEqual(report.badfilterCount, 1)
        XCTAssertEqual(rules.count, 0)
        XCTAssertEqual(report.compiledRuleCount, 0)
    }
}
