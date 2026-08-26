import XCTest
@testable import ADBLX

final class SafariAllowlistCompilerTests: XCTestCase {
    func testEmptyAllowlistProducesEmptyRules() throws {
        let rules = SafariAllowlistCompiler.compile(domains: [])
        XCTAssertTrue(rules.isEmpty)
        
        let data = try SafariAllowlistCompiler.encode(rules: rules)
        let decoded = try JSONDecoder().decode([SafariContentBlockerRule].self, from: data)
        XCTAssertTrue(decoded.isEmpty)
    }
    
    func testSingleDomainProducesSingleExceptionRule() throws {
        let rules = SafariAllowlistCompiler.compile(domains: ["example.com"])
        XCTAssertEqual(rules.count, 1)
        
        let rule = rules[0]
        XCTAssertEqual(rule.trigger.urlFilter, ".*")
        XCTAssertEqual(rule.trigger.ifDomain, ["*example.com"])
        XCTAssertEqual(rule.action.type, "ignore-previous-rules")
        
        let data = try SafariAllowlistCompiler.encode(rules: rules)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("\"action\""))
        XCTAssertTrue(jsonString.contains("\"type\" : \"ignore-previous-rules\"") || jsonString.contains("\"type\":\"ignore-previous-rules\""))
        XCTAssertTrue(jsonString.contains("\"if-domain\""))
        XCTAssertTrue(jsonString.contains("\"*example.com\""))
    }
    
    func testMultipleDomainsProduceDeterministicSortedRules() throws {
        let domains = ["zebra.com", "apple.com", "medium.com", "github.com"]
        let rules = SafariAllowlistCompiler.compile(domains: domains)
        XCTAssertEqual(rules.count, 4)
        
        // Deterministic sorting by domain
        XCTAssertEqual(rules[0].trigger.ifDomain, ["*apple.com"])
        XCTAssertEqual(rules[1].trigger.ifDomain, ["*github.com"])
        XCTAssertEqual(rules[2].trigger.ifDomain, ["*medium.com"])
        XCTAssertEqual(rules[3].trigger.ifDomain, ["*zebra.com"])
    }
    
    func testDuplicateDomainsAreDeduplicated() throws {
        let domains = ["example.com", "example.com", "EXAMPLE.COM"]
        let rules = SafariAllowlistCompiler.compile(domains: domains)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].trigger.ifDomain, ["*example.com"])
    }
    
    func testSubdomainPreservesSpecificWildcard() throws {
        let rules = SafariAllowlistCompiler.compile(domains: ["news.ycombinator.com"])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].trigger.ifDomain, ["*news.ycombinator.com"])
    }
    
    func testCodableRoundTripValidity() throws {
        let originalRules = SafariAllowlistCompiler.compile(domains: ["nytimes.com", "wsj.com"])
        let data = try SafariAllowlistCompiler.encode(rules: originalRules)
        let decodedRules = try JSONDecoder().decode([SafariContentBlockerRule].self, from: data)
        XCTAssertEqual(originalRules, decodedRules)
    }
}
