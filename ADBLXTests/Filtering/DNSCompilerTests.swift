import XCTest
@testable import ADBLX
import ADBLXShared

final class DNSCompilerTests: XCTestCase {
    
    // MARK: - Normalizer Tests
    
    func testNormalizerABPSyntax() {
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "||doubleclick.net^"), "net.doubleclick")
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "||ad.doubleclick.net^"), "net.doubleclick.ad")
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "||sub.sub.doubleclick.net^"), "net.doubleclick.sub.sub")
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "@@||allow.example.com^"), "com.example.allow")
    }
    
    func testNormalizerHostsSyntax() {
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "0.0.0.0 ads.google.com"), "com.google.ads")
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "127.0.0.1 tracker.analytics.io"), "io.analytics.tracker")
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "0.0.0.0 doubleclick.net # Tracker"), "net.doubleclick")
    }
    
    func testNormalizerCommentsAndEmptyLines() {
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "# This is a comment"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "! Title: OISD"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "// Comment"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "   "))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: ""))
    }
    
    func testNormalizerInvalidSyntaxAndWildcardsRejected() {
        // In-string wildcards must be rejected (not broadened)
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "||ad-*.example.com^"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "*.example.com"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "http://example.com/path"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "example.com:8080"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "192.168.1.1"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "::1"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "singlelabel"))
    }
    
    func testNormalizerCaseInsensitivityAndTrimming() {
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "  TRACKER.Example.COM.  "), "com.example.tracker")
    }
    
    // MARK: - Compiler & Serialization Tests
    
    func testBlocklistCompilerValidation() throws {
        let feed1 = """
        # Feed 1
        ||doubleclick.net^
        0.0.0.0 ad.doubleclick.net
        ||tracker.com^
        """
        
        let feed2 = """
        # Feed 2
        127.0.0.1 analytics.google.com
        ||tracker.com^
        0.0.0.0 doubleclick.net
        """
        
        let compiler = DNSBlocklistCompiler()
        let binaryData = try compiler.compile(sourceContents: [feed1, feed2])
        
        let header = try DNSArtifactValidator.validate(data: binaryData)
        // Expected unique rules:
        // "com.google.analytics", "com.tracker", "net.doubleclick", "net.doubleclick.ad"
        XCTAssertEqual(header.ruleCount, 4)
        XCTAssertEqual(header.version, 1)
        XCTAssertEqual(header.magic, DNSArtifactFormat.magicUInt32)
    }
    
    func testAllowlistCompilerValidation() throws {
        let rules = [
            "apple.com",
            "||developer.apple.com^",
            "icloud.com"
        ]
        
        let compiler = DNSAllowlistCompiler()
        let binaryData = try compiler.compile(rules: rules)
        
        let header = try DNSArtifactValidator.validate(data: binaryData)
        XCTAssertEqual(header.ruleCount, 3)
    }
    
    func testCompilerDeterminism() throws {
        let feed = """
        ||z.com^
        0.0.0.0 a.com
        ||m.com^
        127.0.0.1 b.com
        """
        
        let compiler = DNSBlocklistCompiler()
        let run1 = try compiler.compile(sourceContents: [feed])
        let run2 = try compiler.compile(sourceContents: [feed])
        
        XCTAssertEqual(run1, run2, "Compiling identical feeds must produce bit-for-bit identical binary output")
    }
}
