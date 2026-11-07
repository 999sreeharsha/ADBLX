import XCTest
@testable import ADBLX
import ADBLXShared

final class WebExtensionSchemaValidatorTests: XCTestCase {
    private let validator = WebExtensionSchemaValidator()
    
    private func validSampleRulesJSON() -> String {
        """
        {
          "schemaVersion": 1,
          "generation": 1,
          "publishedAt": 1787654400,
          "youtube": {
            "disableMask": {
              "youtubeLayer3Disabled": false,
              "skipClickDisabled": false,
              "accelerationDisabled": false,
              "cosmeticHidingDisabled": false,
              "disabledDomains": ["m.youtube.com"]
            },
            "selectors": {
              "playerContainers": ["#movie_player", ".html5-video-player"],
              "adStateClasses": ["ad-showing", "ad-interrupting"],
              "skipButtons": [".ytp-ad-skip-button", ".ytm-skip-ad-button"],
              "adBadges": [".ytp-ad-text", ".ytm-ad-badge"],
              "cosmeticHideTargets": [".ytp-ad-player-overlay", "ytm-promoted-sparkles-web-renderer"]
            },
            "parameters": {
              "maxAccelerationRate": 16.0,
              "candidateConfirmationWindowMs": 100,
              "safeRecoveryStabilityWindowMs": 500
            }
          },
          "cosmetics": {
            "genericHideSelectors": [],
            "domainSpecificHideSelectors": {}
          },
          "antiAdblock": {
            "knownInterventions": []
          }
        }
        """
    }
    
    func testValidRulesJSONPasses() throws {
        let data = validSampleRulesJSON().data(using: .utf8)!
        XCTAssertNoThrow(try validator.validate(rulesData: data))
    }
    
    func testPayloadTooLargeRejected() {
        let largeData = Data(repeating: 0x41, count: WebExtensionArtifactFormat.maxRulesSizeBytes + 1)
        XCTAssertThrowsError(try validator.validate(rulesData: largeData)) { error in
            guard case WebExtensionValidationError.payloadTooLarge = error else {
                XCTFail("Expected payloadTooLarge, got \(error)")
                return
            }
        }
    }
    
    func testInvalidJSONSyntaxRejected() {
        let invalidData = "{ bad json syntax".data(using: .utf8)!
        XCTAssertThrowsError(try validator.validate(rulesData: invalidData)) { error in
            guard case WebExtensionValidationError.invalidJSON = error else {
                XCTFail("Expected invalidJSON, got \(error)")
                return
            }
        }
    }
    
    func testUnsupportedSchemaVersionRejected() {
        let json = "{\"schemaVersion\": 99}".data(using: .utf8)!
        XCTAssertThrowsError(try validator.validate(rulesData: json)) { error in
            guard case WebExtensionValidationError.unsupportedSchemaVersion(99) = error else {
                XCTFail("Expected unsupportedSchemaVersion(99), got \(error)")
                return
            }
        }
    }
    
    func testOutOfRangeAccelerationRateRejected() {
        let jsonLow = validSampleRulesJSON().replacingOccurrences(of: "\"maxAccelerationRate\": 16.0", with: "\"maxAccelerationRate\": 0.5").data(using: .utf8)!
        XCTAssertThrowsError(try validator.validate(rulesData: jsonLow)) { error in
            guard case WebExtensionValidationError.outOfRangeParameter(let param, let val, _, _) = error else {
                XCTFail("Expected outOfRangeParameter, got \(error)")
                return
            }
            XCTAssertEqual(param, "maxAccelerationRate")
            XCTAssertEqual(val, 0.5)
        }
        
        let jsonHigh = validSampleRulesJSON().replacingOccurrences(of: "\"maxAccelerationRate\": 16.0", with: "\"maxAccelerationRate\": 32.0").data(using: .utf8)!
        XCTAssertThrowsError(try validator.validate(rulesData: jsonHigh)) { error in
            guard case WebExtensionValidationError.outOfRangeParameter(let param, let val, _, _) = error else {
                XCTFail("Expected outOfRangeParameter, got \(error)")
                return
            }
            XCTAssertEqual(param, "maxAccelerationRate")
            XCTAssertEqual(val, 32.0)
        }
    }
    
    func testOutOfRangeConfirmationWindowRejected() {
        let jsonLow = validSampleRulesJSON().replacingOccurrences(of: "\"candidateConfirmationWindowMs\": 100", with: "\"candidateConfirmationWindowMs\": 5").data(using: .utf8)!
        XCTAssertThrowsError(try validator.validate(rulesData: jsonLow))
        
        let jsonHigh = validSampleRulesJSON().replacingOccurrences(of: "\"candidateConfirmationWindowMs\": 100", with: "\"candidateConfirmationWindowMs\": 2000").data(using: .utf8)!
        XCTAssertThrowsError(try validator.validate(rulesData: jsonHigh))
    }
    
    func testOutOfRangeRecoveryWindowRejected() {
        let jsonLow = validSampleRulesJSON().replacingOccurrences(of: "\"safeRecoveryStabilityWindowMs\": 500", with: "\"safeRecoveryStabilityWindowMs\": 10").data(using: .utf8)!
        XCTAssertThrowsError(try validator.validate(rulesData: jsonLow))
        
        let jsonHigh = validSampleRulesJSON().replacingOccurrences(of: "\"safeRecoveryStabilityWindowMs\": 500", with: "\"safeRecoveryStabilityWindowMs\": 10000").data(using: .utf8)!
        XCTAssertThrowsError(try validator.validate(rulesData: jsonHigh))
    }
    
    func testProhibitedSelectorConstructRejected() {
        let jsonProhibited = validSampleRulesJSON().replacingOccurrences(
            of: "\".ytp-ad-skip-button\"",
            with: "\".ytp-ad-skip-button[onclick*=\\\"javascript:alert(1)\\\"]\""
        ).data(using: .utf8)!
        
        XCTAssertThrowsError(try validator.validate(rulesData: jsonProhibited)) { error in
            guard case WebExtensionValidationError.prohibitedSelectorConstruct = error else {
                XCTFail("Expected prohibitedSelectorConstruct, got \(error)")
                return
            }
        }
    }
    
    // content.js joins the hide selectors into one CSS rule (`a, b { display: none }`), so a
    // selector that closes the rule or opens a block, an at-rule or a url() could add CSS of its
    // own: restyle the page, or fetch a URL as a tracking pixel (SEC-11). Selectors never need these.
    func testSelectorThatCouldEscapeTheHideRuleIsRejected() {
        let escapes = [
            ".ad } body { background: url(https://example.invalid/p) }",
            ".ad{display:block}",
            "@import \\\"https://example.invalid/x.css\\\"",
            ".ad[style*=\\\"url(https://example.invalid)\\\"]"
        ]
        for escape in escapes {
            let json = validSampleRulesJSON().replacingOccurrences(
                of: "\".ytp-ad-player-overlay\"", with: "\"\(escape)\""
            ).data(using: .utf8)!
            XCTAssertThrowsError(try validator.validate(rulesData: json), escape) { error in
                guard case WebExtensionValidationError.prohibitedSelectorConstruct = error else {
                    XCTFail("Expected prohibitedSelectorConstruct for \(escape), got \(error)")
                    return
                }
            }
        }
    }

    func testShippedDefaultRulesPass() throws {
        try validator.validate(rulesData: Data(WebExtensionBootstrap.defaultRulesJSON.utf8))
    }

    func testSelectorTooLongRejected() {
        let longSelector = String(repeating: "a", count: 300)
        let jsonLong = validSampleRulesJSON().replacingOccurrences(
            of: "\".ytp-ad-skip-button\"",
            with: "\"\(longSelector)\""
        ).data(using: .utf8)!
        
        XCTAssertThrowsError(try validator.validate(rulesData: jsonLong)) { error in
            guard case WebExtensionValidationError.selectorTooLong = error else {
                XCTFail("Expected selectorTooLong, got \(error)")
                return
            }
        }
    }
    
    func testSelectorCombinatorDepthExceededRejected() {
        let deepSelector = "div > span > a > b > i > u" // Depth 5
        let jsonDeep = validSampleRulesJSON().replacingOccurrences(
            of: "\".ytp-ad-skip-button\"",
            with: "\"\(deepSelector)\""
        ).data(using: .utf8)!
        
        XCTAssertThrowsError(try validator.validate(rulesData: jsonDeep)) { error in
            guard case WebExtensionValidationError.selectorCombinatorDepthExceeded = error else {
                XCTFail("Expected selectorCombinatorDepthExceeded, got \(error)")
                return
            }
        }
    }
    
    func testInvalidDomainInDisableMaskRejected() {
        let jsonInvalidDomain = validSampleRulesJSON().replacingOccurrences(
            of: "\"disabledDomains\": [\"m.youtube.com\"]",
            with: "\"disabledDomains\": [\"unauthorized-origin.com\"]"
        ).data(using: .utf8)!
        
        XCTAssertThrowsError(try validator.validate(rulesData: jsonInvalidDomain)) { error in
            guard case WebExtensionValidationError.invalidDomainInDisableMask(let domain) = error else {
                XCTFail("Expected invalidDomainInDisableMask, got \(error)")
                return
            }
            XCTAssertEqual(domain, "unauthorized-origin.com")
        }
    }
}
