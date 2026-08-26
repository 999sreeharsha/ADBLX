import XCTest
@testable import ADBLX

final class SafariDomainNormalizerTests: XCTestCase {
    func testValidStandardDomains() throws {
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "example.com"), "example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "sub.example.com"), "sub.example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "deep.sub.domain.co.uk"), "deep.sub.domain.co.uk")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "my-site-123.org"), "my-site-123.org")
    }
    
    func testCaseInsensitiveNormalization() throws {
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "EXAMPLE.COM"), "example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "Sub.Domain.ORG"), "sub.domain.org")
    }
    
    func testWhitespaceAndTrailingDotTrimming() throws {
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "  example.com  \n"), "example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "example.com."), "example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "...example.com..."), "example.com")
    }
    
    func testURLStripping() throws {
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "https://example.com"), "example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "http://example.com/some/path?param=1#section"), "example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "ws://sub.example.com:8080/feed"), "sub.example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "example.com:8443"), "example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "example.com/test"), "example.com")
    }
    
    func testWildcardPrefixStripping() throws {
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "*.example.com"), "example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "*example.com"), "example.com")
        XCTAssertEqual(try SafariDomainNormalizer.normalize(input: "||example.com^"), "example.com")
    }
    
    func testSubdomainDistinctness() throws {
        let parent = try SafariDomainNormalizer.normalize(input: "example.com")
        let child = try SafariDomainNormalizer.normalize(input: "sub.example.com")
        XCTAssertNotEqual(parent, child)
    }
    
    func testEmptyInputRejection() {
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .emptyInput)
        }
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "   \n\t ")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .emptyInput)
        }
    }
    
    func testIPLiteralRejection() {
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "127.0.0.1")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .ipAddressNotSupported)
        }
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "192.168.1.1")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .ipAddressNotSupported)
        }
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "::1")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .ipAddressNotSupported)
        }
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "2001:db8::1")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .ipAddressNotSupported)
        }
    }
    
    func testLocalhostAndSingleLabelRejection() {
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "localhost")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .localhostNotSupported)
        }
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "internal")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .invalidFormat("Single label domains are not supported"))
        }
    }
    
    func testIllegalCharactersAndDoubleDotsRejection() {
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "example..com")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .invalidFormat("Empty label found in domain"))
        }
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "example_domain.com")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .invalidFormat("Invalid character in domain label"))
        }
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "exam$ple.com")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .invalidFormat("Invalid character in domain label"))
        }
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "-example.com")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .invalidFormat("Label cannot start or end with a hyphen"))
        }
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "example-.com")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .invalidFormat("Label cannot start or end with a hyphen"))
        }
    }
    
    func testLengthBoundaryRejection() {
        let label64 = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: "\(label64).com")) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .labelLengthExceeded)
        }
        
        let label63 = String(repeating: "a", count: 63)
        let domain256 = "\(label63).\(label63).\(label63).\(label63).com"
        XCTAssertThrowsError(try SafariDomainNormalizer.normalize(input: domain256)) { error in
            XCTAssertEqual(error as? SafariDomainNormalizerError, .domainLengthExceeded)
        }
    }
}
