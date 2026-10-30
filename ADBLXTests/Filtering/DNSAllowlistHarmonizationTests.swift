// ADBLXTests/Filtering/DNSAllowlistHarmonizationTests.swift
import XCTest
@testable import ADBLX
import ADBLXShared

@MainActor
final class DNSAllowlistHarmonizationTests: XCTestCase {
    private var store: FilterStore!
    private var allowlistStore: AllowlistStore!
    private var dnsSettingsStore: DNSProtectionSettingsStore!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        store = FilterStore.temporary()
        allowlistStore = AllowlistStore(store: store)
        let defaults = UserDefaults(suiteName: "test.dns.harmonization.\(UUID().uuidString)")!
        dnsSettingsStore = DNSProtectionSettingsStore(userDefaults: defaults)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testDomainNormalizationAndValidation() {
        // Valid domains
        XCTAssertEqual(DNSProtectionSettingsStore.validateDomain("Example.COM"), "example.com")
        XCTAssertEqual(DNSProtectionSettingsStore.validateDomain("  sub.domain.org  "), "sub.domain.org")
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "||ad.doubleclick.net^"), "net.doubleclick.ad")
        XCTAssertEqual(DNSDomainNormalizer.normalizeToReversedDomain(line: "0.0.0.0 tracker.com"), "com.tracker")

        // Invalid domains
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "||ad-*.example.com^"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "http://example.com/path"))
        XCTAssertNil(DNSDomainNormalizer.normalizeToReversedDomain(line: "192.168.1.1"))
    }

    func testAllowlistPrecedenceOverC2Blocklist() throws {
        let publisher = DNSArtifactPublisher()
        
        let blocklist = [
            "||doubleclick.net^",
            "||telemetry.apple.com^",
            "||tracker.io^"
        ]
        let allowlist = [
            "||doubleclick.net^" // User unblocks doubleclick
        ]
        
        _ = try publisher.publish(
            blocklistSources: [blocklist.joined(separator: "\n")],
            allowlistRules: allowlist,
            baseAppGroupURL: tempDir
        )
        
        let loader = DNSGenerationLoader()
        let snapshot = try loader.loadActiveGeneration(baseAppGroupURL: tempDir)
        let engine = DNSLookupEngine(initialSnapshot: snapshot)
        
        // Blocked items
        XCTAssertEqual(engine.lookup(domain: "telemetry.apple.com"), .block)
        XCTAssertEqual(engine.lookup(domain: "tracker.io"), .block)
        
        // Allowlisted item overrides blocklist
        XCTAssertEqual(engine.lookup(domain: "doubleclick.net"), .allow)
        XCTAssertEqual(engine.lookup(domain: "ad.doubleclick.net"), .allow)
    }

    func testUpstreamResolverConfigurationValidation() {
        // Quad9 defaults
        let quad9Settings = DNSProtectionSettings()
        XCTAssertEqual(quad9Settings.resolverOption, UpstreamResolverOption.quad9Default)
        XCTAssertEqual(quad9Settings.customIPv4, "9.9.9.9")
        XCTAssertEqual(quad9Settings.customIPv6, "2620:fe::fe")

        // Custom Resolver Validation
        XCTAssertTrue(DNSProtectionSettingsStore.validateIPv4("1.1.1.1"))
        XCTAssertTrue(DNSProtectionSettingsStore.validateIPv4("192.168.1.1"))
        XCTAssertFalse(DNSProtectionSettingsStore.validateIPv4("999.999.999.999"))
        XCTAssertFalse(DNSProtectionSettingsStore.validateIPv4("invalid-ip"))

        XCTAssertTrue(DNSProtectionSettingsStore.validateIPv6("2606:4700:4700::1111"))
        XCTAssertTrue(DNSProtectionSettingsStore.validateIPv6("::1"))
        XCTAssertFalse(DNSProtectionSettingsStore.validateIPv6("invalid-ipv6"))
    }
}
