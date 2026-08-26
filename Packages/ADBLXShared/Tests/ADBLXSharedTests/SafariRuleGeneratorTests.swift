import XCTest
@testable import ADBLXShared

final class SafariRuleGeneratorTests: XCTestCase {
    func testGenerateDomainAnchorBlockRule() {
        let pattern = ABPPattern.domainAnchor("doubleclick.net")
        let net = ValidatedNetworkRule(
            pattern: pattern,
            isException: false,
            loadType: .thirdParty,
            resourceTypes: [.script]
        )
        let rules = SafariRuleGenerator.generate(from: .network(net))
        XCTAssertEqual(rules.count, 1)
        
        let rule = rules[0]
        XCTAssertEqual(rule.action.type, "block")
        XCTAssertEqual(rule.trigger.urlFilter, "^https?://([a-zA-Z0-9-]+\\.)*doubleclick\\.net")
        XCTAssertEqual(rule.trigger.loadType, ["third-party"])
        XCTAssertEqual(rule.trigger.resourceType, ["script"])
    }
    
    func testGenerateUrlPrefixAndWildcardRules() {
        let pattern1 = ABPPattern.urlPrefix("http://example.com/ad.js")
        let net1 = ValidatedNetworkRule(pattern: pattern1, isException: false)
        let rules1 = SafariRuleGenerator.generate(from: .network(net1))
        XCTAssertEqual(rules1[0].trigger.urlFilter, "^http://example\\.com/ad\\.js")
        
        let pattern2 = ABPPattern.wildcard("/banner_*.gif")
        let net2 = ValidatedNetworkRule(pattern: pattern2, isException: false)
        let rules2 = SafariRuleGenerator.generate(from: .network(net2))
        XCTAssertEqual(rules2[0].trigger.urlFilter, "/banner_.*\\.gif")
    }
    
    func testGenerateExactMatchRule() {
        let pattern = ABPPattern.exactMatch("tracker.com/pixel.gif")
        let net = ValidatedNetworkRule(pattern: pattern, isException: false)
        let rules = SafariRuleGenerator.generate(from: .network(net))
        XCTAssertEqual(rules[0].trigger.urlFilter, "^https?://([a-zA-Z0-9-]+\\.)*tracker\\.com/pixel\\.gif$")
    }
    
    func testGenerateCosmeticElementHidingRule() {
        let cos = ValidatedCosmeticRule(
            ifDomains: ["*example.com", "*site.org"],
            unlessDomains: ["*safe.com"],
            isException: false,
            selector: ".ad-banner"
        )
        let rules = SafariRuleGenerator.generate(from: .cosmetic(cos))
        XCTAssertEqual(rules.count, 1)
        
        let rule = rules[0]
        XCTAssertEqual(rule.action.type, "css-display-none")
        XCTAssertEqual(rule.action.selector, ".ad-banner")
        XCTAssertEqual(rule.trigger.urlFilter, ".*")
        XCTAssertEqual(rule.trigger.ifDomain, ["*example.com", "*site.org"])
        XCTAssertEqual(rule.trigger.unlessDomain, ["*safe.com"])
    }
    
    func testGenerateExceptionRules() {
        let pattern = ABPPattern.domainAnchor("allowed.com")
        let net = ValidatedNetworkRule(pattern: pattern, isException: true)
        let rules = SafariRuleGenerator.generate(from: .network(net))
        XCTAssertEqual(rules[0].action.type, "ignore-previous-rules")
        XCTAssertEqual(rules[0].trigger.urlFilter, "^https?://([a-zA-Z0-9-]+\\.)*allowed\\.com")
    }
}
