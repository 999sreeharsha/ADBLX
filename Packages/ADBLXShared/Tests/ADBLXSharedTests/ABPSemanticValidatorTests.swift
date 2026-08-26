import XCTest
@testable import ADBLXShared

final class ABPSemanticValidatorTests: XCTestCase {
    func testValidateSupportedThirdPartyAndResourceTypes() {
        let parsed = ABPParser.parse(line: "||ads.example.com^$third-party,script,image")
        let disposition = ABPSemanticValidator.validate(parsed)
        
        guard case .supported(let val) = disposition, case .network(let net) = val else {
            XCTFail("Expected supported network rule, got \(disposition)")
            return
        }
        XCTAssertEqual(net.loadType, .thirdParty)
        XCTAssertEqual(net.resourceTypes, [.script, .image])
        XCTAssertFalse(net.isException)
    }
    
    func testValidateNegatedLoadType() {
        let parsed = ABPParser.parse(line: "||analytics.com^$~third-party")
        let disposition = ABPSemanticValidator.validate(parsed)
        
        guard case .supported(let val) = disposition, case .network(let net) = val else {
            XCTFail("Expected supported network rule")
            return
        }
        XCTAssertEqual(net.loadType, .firstParty)
    }
    
    func testValidateNegatedResourceTypeComplement() {
        let parsed = ABPParser.parse(line: "||cdn.example.com^$~image")
        let disposition = ABPSemanticValidator.validate(parsed)
        
        guard case .supported(let val) = disposition, case .network(let net) = val else {
            XCTFail("Expected supported network rule")
            return
        }
        let expected = SafariResourceType.filterableSubresources.subtracting([.image])
        XCTAssertEqual(net.resourceTypes, expected)
    }
    
    func testValidateMultipleNegatedResourceTypes() {
        let parsed = ABPParser.parse(line: "||cdn.example.com^$~image,~script")
        let disposition = ABPSemanticValidator.validate(parsed)
        
        guard case .supported(let val) = disposition, case .network(let net) = val else {
            XCTFail("Expected supported network rule")
            return
        }
        let expected = SafariResourceType.filterableSubresources.subtracting([.image, .script])
        XCTAssertEqual(net.resourceTypes, expected)
    }
    
    func testValidateDomainOptionParsing() {
        let parsed = ABPParser.parse(line: "||tracker.com^$domain=example.com|site.org|~safe.com")
        let disposition = ABPSemanticValidator.validate(parsed)
        
        guard case .supported(let val) = disposition, case .network(let net) = val else {
            XCTFail("Expected supported network rule")
            return
        }
        XCTAssertEqual(net.ifDomains, ["*example.com", "*site.org"])
        XCTAssertEqual(net.unlessDomains, ["*safe.com"])
    }
    
    func testValidateUnsupportedSemanticModifiersSkipRule() {
        let modifiers = ["popup", "csp", "redirect", "rewrite", "important", "generichide", "badfilter", "match-case"]
        for mod in modifiers {
            let parsed = ABPParser.parse(line: "||ad.com^$\(mod)")
            let disposition = ABPSemanticValidator.validate(parsed)
            
            guard case .unsupportedSemantic(let reason, let m) = disposition else {
                XCTFail("Expected unsupportedSemantic for $\(mod), got \(disposition)")
                continue
            }
            XCTAssertEqual(m, mod)
            XCTAssertFalse(reason.isEmpty)
        }
    }
    
    func testValidateCosmeticAndExceptions() {
        let parsedCos = ABPParser.parse(line: "example.com##.sponsor-banner")
        let dispCos = ABPSemanticValidator.validate(parsedCos)
        guard case .supported(.cosmetic(let cos)) = dispCos else {
            XCTFail("Expected supported cosmetic rule")
            return
        }
        XCTAssertEqual(cos.ifDomains, ["*example.com"])
        XCTAssertEqual(cos.selector, ".sponsor-banner")
        XCTAssertFalse(cos.isException)
        
        let parsedEx = ABPParser.parse(line: "@@||news.com^$document")
        let dispEx = ABPSemanticValidator.validate(parsedEx)
        guard case .supported(.network(let ex)) = dispEx else {
            XCTFail("Expected supported exception rule")
            return
        }
        XCTAssertTrue(ex.isException)
    }
    
    func testValidateDeferredScriptletsAndProceduralCSS() {
        let parsed1 = ABPParser.parse(line: "example.com##+js(set, ad, 0)")
        let disp1 = ABPSemanticValidator.validate(parsed1)
        guard case .deferredToWebExtension = disp1 else {
            XCTFail("Expected deferredToWebExtension for scriptlet")
            return
        }
        
        let parsed2 = ABPParser.parse(line: "example.com#?#div:has(> .banner)")
        let disp2 = ABPSemanticValidator.validate(parsed2)
        guard case .deferredToWebExtension = disp2 else {
            XCTFail("Expected deferredToWebExtension for procedural CSS")
            return
        }
    }
}
