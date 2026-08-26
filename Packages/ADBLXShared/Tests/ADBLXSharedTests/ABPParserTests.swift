import XCTest
@testable import ADBLXShared

final class ABPParserTests: XCTestCase {
    func testParseCommentsAndEmpty() {
        XCTAssertEqual(ABPParser.parse(line: ""), .empty)
        XCTAssertEqual(ABPParser.parse(line: "! Some comment"), .comment("! Some comment"))
    }
    
    func testParseNetworkDomainAnchorRule() {
        let rule = ABPParser.parse(line: "||doubleclick.net^$third-party,script")
        guard case .network(let netRule) = rule else {
            XCTFail("Expected .network rule, got \(rule)")
            return
        }
        XCTAssertEqual(netRule.pattern, .domainAnchor("doubleclick.net"))
        XCTAssertFalse(netRule.isException)
        XCTAssertEqual(netRule.rawModifiers, ["third-party", "script"])
    }
    
    func testParseNetworkExactURLAndPrefixRules() {
        let rule1 = ABPParser.parse(line: "|http://example.com/ad.js")
        guard case .network(let netRule1) = rule1 else {
            XCTFail("Expected .network rule")
            return
        }
        XCTAssertEqual(netRule1.pattern, .urlPrefix("http://example.com/ad.js"))
        
        let rule2 = ABPParser.parse(line: "||tracker.com/pixel.gif|")
        guard case .network(let netRule2) = rule2 else {
            XCTFail("Expected .network rule")
            return
        }
        XCTAssertEqual(netRule2.pattern, .exactMatch("tracker.com/pixel.gif"))
    }
    
    func testParseNetworkWildcardAndRegexRules() {
        let rule1 = ABPParser.parse(line: "/banner_*.gif$image")
        guard case .network(let netRule1) = rule1 else {
            XCTFail("Expected .network rule")
            return
        }
        XCTAssertEqual(netRule1.pattern, .wildcard("/banner_*.gif"))
        
        let rule2 = ABPParser.parse(line: "/^https?:\\/\\/.*adserver/$image")
        guard case .network(let netRule2) = rule2 else {
            XCTFail("Expected .network rule")
            return
        }
        XCTAssertEqual(netRule2.pattern, .regularExpression("^https?:\\/\\/.*adserver"))
    }
    
    func testParseNetworkExceptionRules() {
        let rule = ABPParser.parse(line: "@@||news.ycombinator.com^$document")
        guard case .network(let netRule) = rule else {
            XCTFail("Expected .network exception rule")
            return
        }
        XCTAssertEqual(netRule.pattern, .domainAnchor("news.ycombinator.com"))
        XCTAssertTrue(netRule.isException)
        XCTAssertEqual(netRule.rawModifiers, ["document"])
    }
    
    func testParseCosmeticRules() {
        let rule1 = ABPParser.parse(line: "##.ad-header")
        guard case .cosmetic(let cos1) = rule1 else {
            XCTFail("Expected .cosmetic rule")
            return
        }
        XCTAssertEqual(cos1.domains, [])
        XCTAssertEqual(cos1.selector, ".ad-header")
        XCTAssertFalse(cos1.isException)
        
        let rule2 = ABPParser.parse(line: "nytimes.com,wsj.com##.sponsor-box")
        guard case .cosmetic(let cos2) = rule2 else {
            XCTFail("Expected .cosmetic rule")
            return
        }
        XCTAssertEqual(cos2.domains, ["nytimes.com", "wsj.com"])
        XCTAssertEqual(cos2.selector, ".sponsor-box")
        XCTAssertFalse(cos2.isException)
        
        let rule3 = ABPParser.parse(line: "example.com#@#.ad-header")
        guard case .cosmetic(let cos3) = rule3 else {
            XCTFail("Expected .cosmetic exception rule")
            return
        }
        XCTAssertEqual(cos3.domains, ["example.com"])
        XCTAssertEqual(cos3.selector, ".ad-header")
        XCTAssertTrue(cos3.isException)
    }
    
    func testParseDeferredScriptletAndProceduralRules() {
        let rule1 = ABPParser.parse(line: "example.com##+js(set, ads, 0)")
        guard case .deferred(let def1) = rule1 else {
            XCTFail("Expected .deferred rule")
            return
        }
        XCTAssertEqual(def1.kind, .scriptlet)
        XCTAssertEqual(def1.rawText, "example.com##+js(set, ads, 0)")
        
        let rule2 = ABPParser.parse(line: "example.com#?#div:has(> .banner)")
        guard case .deferred(let def2) = rule2 else {
            XCTFail("Expected .deferred procedural rule")
            return
        }
        XCTAssertEqual(def2.kind, .proceduralCSS)
    }
}
