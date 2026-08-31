import XCTest
@testable import ADBLX
import ADBLXShared

final class DNSCompilerTests: XCTestCase {
    
    // MARK: - Normalizer Tests
    
    func testNormalizerABPSyntax() {
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "||doubleclick.net^"), "net.doubleclick")
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "||ad.doubleclick.net^"), "net.doubleclick.ad")
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "||sub.sub.doubleclick.net^"), "net.doubleclick.sub.sub")
    }
    
    func testNormalizerRejectsCosmeticAndProceduralFilters() {
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "google.com##.GC3LC41DERB"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "whatsapp.com###cookie-policy-banner"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "example.com#?#div[jsname=\"wA2P2b\"]"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "example.com#@#.ad-banner"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "example.com#$#style"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "example.com#%#script"))
    }
    
    func testNormalizerRejectsExceptionRulesAndDollarOptions() {
        // Exception rules must never be inverted into block directives
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "@@||allow.example.com^"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "@@||google.com^$generichide"))
        
        // Rules with context-dependent options must be rejected
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "||google.com^$third-party"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "||doubleclick.net^$image,script"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "||tracker.com^$domain=example.com"))
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
    
    func testInverseAdSubdomainBlockingPreserved() throws {
        let feed = """
        0.0.0.0 adservice.google.com
        0.0.0.0 analytics.google.com
        ||doubleclick.net^
        """
        let compiler = DNSBlocklistCompiler()
        let binaryData = try compiler.compile(sourceContents: [feed])
        let header = try DNSArtifactValidator.validate(data: binaryData)
        let blockArtifact = MappedDNSArtifact(validatedData: binaryData, header: header)
        let emptyHeader = DNSArtifactHeader(ruleCount: 0, stringBlobSize: 0, payloadCRC32: 0)
        let emptyAllow = MappedDNSArtifact(validatedData: emptyHeader.serialize(), header: emptyHeader)
        let snapshot = DNSLookupSnapshot(generation: 1, blocklist: blockArtifact, allowlist: emptyAllow)
        let engine = DNSLookupEngine(initialSnapshot: snapshot)
        
        // Ad subdomains MUST be blocked
        XCTAssertEqual(engine.lookup(domain: "adservice.google.com"), .block)
        XCTAssertEqual(engine.lookup(domain: "analytics.google.com"), .block)
        XCTAssertEqual(engine.lookup(domain: "ad.doubleclick.net"), .block)
        
        // Root domains must NOT be blocked
        XCTAssertEqual(engine.lookup(domain: "google.com"), .allow)
        XCTAssertEqual(engine.lookup(domain: "www.google.com"), .allow)
    }
}
