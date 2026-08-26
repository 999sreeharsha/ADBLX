import XCTest
import os
@testable import ADBLX
import ADBLXShared

final class DNSRuntimeLookupTests: XCTestCase {
    private var tempAppGroupURL: URL!
    private let fileManager = FileManager.default
    
    override func setUp() {
        super.setUp()
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempAppGroupURL = tempDir
    }
    
    override func tearDown() {
        try? fileManager.removeItem(at: tempAppGroupURL)
        super.tearDown()
    }
    
    // MARK: - Precedence and Suffix Matching Tests
    
    func testPrecedenceAndSuffixMatching() throws {
        let publisher = DNSArtifactPublisher()
        
        let blocklist = [
            "||doubleclick.net^",
            "||tracker.com^",
            "||analytics.google.com^",
            "||blocked-parent.org^"
        ]
        
        let allowlist = [
            "||allowlisted.doubleclick.net^", // Subdomain exception
            "||developer.apple.com^",
            "wikipedia.org"
        ]
        
        _ = try publisher.publish(
            blocklistSources: [blocklist.joined(separator: "\n")],
            allowlistRules: allowlist,
            baseAppGroupURL: tempAppGroupURL
        )
        
        let loader = DNSGenerationLoader()
        let snapshot = try loader.loadActiveGeneration(baseAppGroupURL: tempAppGroupURL)
        let engine = DNSLookupEngine(initialSnapshot: snapshot)
        
        // 1. Direct Blocked Hits
        XCTAssertEqual(engine.lookup(domain: "doubleclick.net"), .block)
        XCTAssertEqual(engine.lookup(domain: "ad.doubleclick.net"), .block)
        XCTAssertEqual(engine.lookup(domain: "deep.sub.ad.doubleclick.net"), .block)
        XCTAssertEqual(engine.lookup(domain: "analytics.google.com"), .block)
        XCTAssertEqual(engine.lookup(domain: "sub.analytics.google.com"), .block)
        
        // 2. Allowlist Overrides Blocklist (Precedence Test)
        // allowlisted.doubleclick.net is blocked by parent 'doubleclick.net', but allowlist short-circuits it!
        XCTAssertEqual(engine.lookup(domain: "allowlisted.doubleclick.net"), .allow)
        XCTAssertEqual(engine.lookup(domain: "sub.allowlisted.doubleclick.net"), .allow)
        
        // 3. Allowed / Neutral Hits
        XCTAssertEqual(engine.lookup(domain: "google.com"), .allow)
        XCTAssertEqual(engine.lookup(domain: "apple.com"), .allow)
        XCTAssertEqual(engine.lookup(domain: "developer.apple.com"), .allow)
        XCTAssertEqual(engine.lookup(domain: "wikipedia.org"), .allow)
        XCTAssertEqual(engine.lookup(domain: "en.wikipedia.org"), .allow)
        
        // 4. Near Misses (Must NOT Block)
        XCTAssertEqual(engine.lookup(domain: "doubleclick.net.example.com"), .allow)
        XCTAssertEqual(engine.lookup(domain: "my-doubleclick.net"), .allow)
        XCTAssertEqual(engine.lookup(domain: "nottracker.com"), .allow)
        
        // 5. Extreme Length Hostnames
        XCTAssertEqual(engine.lookup(domain: "a.com"), .allow)
        XCTAssertEqual(engine.lookup(domain: "long-cdn-hostname.us-east-1.production.aws.amazon.com"), .allow)
    }
    
    // MARK: - Active-Traffic Concurrent Generation Swap Test
    
    func testActiveTrafficGenerationSwap() throws {
        let publisher = DNSArtifactPublisher()
        
        // Publish Generation 1: doubleclick.net is blocked
        _ = try publisher.publish(
            blocklistSources: ["||doubleclick.net^"],
            allowlistRules: [],
            baseAppGroupURL: tempAppGroupURL
        )
        
        let loader = DNSGenerationLoader()
        let initialSnapshot = try loader.loadActiveGeneration(baseAppGroupURL: tempAppGroupURL)
        let engine = DNSLookupEngine(initialSnapshot: initialSnapshot)
        XCTAssertEqual(engine.activeGeneration, 1)
        
        let isRunning = OSAllocatedUnfairLock(initialState: true)
        let lookupCount = OSAllocatedUnfairLock(initialState: 0)
        let group = DispatchGroup()
        
        // Launch 8 concurrent background lookup threads
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while isRunning.withLock({ $0 }) {
                    let v1 = engine.lookup(domain: "ad.doubleclick.net")
                    let v2 = engine.lookup(domain: "google.com")
                    let v3 = engine.lookup(domain: "newsite.com")
                    
                    // Verify results are always valid and non-crashing
                    XCTAssertTrue(v1 == .block || v1 == .allow)
                    XCTAssertEqual(v2, .allow)
                    XCTAssertTrue(v3 == .block || v3 == .allow)
                    
                    lookupCount.withLock { $0 += 3 }
                }
                group.leave()
            }
        }
        
        // While concurrent lookups are running, publish Generation 2:
        // - newsite.com is now BLOCKED
        // - doubleclick.net is now ALLOWLISTED
        Thread.sleep(forTimeInterval: 0.05)
        
        _ = try publisher.publish(
            blocklistSources: ["||doubleclick.net^", "||newsite.com^"],
            allowlistRules: ["||doubleclick.net^"], // Unblock doubleclick!
            baseAppGroupURL: tempAppGroupURL
        )
        
        // Reload engine while traffic is actively querying
        let reloaded = loader.reloadIfUpdated(engine: engine, baseAppGroupURL: tempAppGroupURL)
        XCTAssertTrue(reloaded)
        XCTAssertEqual(engine.activeGeneration, 2)
        
        // Verify new semantics are immediately active
        XCTAssertEqual(engine.lookup(domain: "ad.doubleclick.net"), .allow)
        XCTAssertEqual(engine.lookup(domain: "newsite.com"), .block)
        
        // Stop background threads
        isRunning.withLock { $0 = false }
        group.wait()
        
        let totalQueries = lookupCount.withLock { $0 }
        XCTAssertGreaterThan(totalQueries, 1000, "Should have executed thousands of concurrent queries without race conditions")
    }
    
    // MARK: - Last-Known-Good Preservation on Corrupted Generation
    
    func testLastKnownGoodPreservedOnCorruptedGeneration() throws {
        let publisher = DNSArtifactPublisher()
        
        // Generation 1
        _ = try publisher.publish(
            blocklistSources: ["||doubleclick.net^"],
            allowlistRules: [],
            baseAppGroupURL: tempAppGroupURL
        )
        
        let loader = DNSGenerationLoader()
        let snapshot1 = try loader.loadActiveGeneration(baseAppGroupURL: tempAppGroupURL)
        let engine = DNSLookupEngine(initialSnapshot: snapshot1)
        XCTAssertEqual(engine.activeGeneration, 1)
        
        // Publish Generation 2
        _ = try publisher.publish(
            blocklistSources: ["||newsite.com^"],
            allowlistRules: [],
            baseAppGroupURL: tempAppGroupURL
        )
        
        // Intentionally corrupt Generation 2's block.bin file (tamper CRC32)
        let gen2Dir = DNSAppGroupPaths.generationDirectory(generationName: "000002", base: tempAppGroupURL)!
        let blockURL = gen2Dir.appendingPathComponent(DNSArtifactFormat.blocklistFilename)
        var corruptedData = try Data(contentsOf: blockURL)
        corruptedData[corruptedData.count - 1] ^= 0xFF // Corrupt last byte
        try corruptedData.write(to: blockURL)
        
        // Attempt reload
        let reloaded = loader.reloadIfUpdated(engine: engine, baseAppGroupURL: tempAppGroupURL)
        
        // Reload must fail and retain Generation 1!
        XCTAssertFalse(reloaded)
        XCTAssertEqual(engine.activeGeneration, 1)
        XCTAssertEqual(engine.lookup(domain: "doubleclick.net"), .block)
    }
}
