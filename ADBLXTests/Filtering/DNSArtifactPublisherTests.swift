import XCTest
@testable import ADBLX
import ADBLXShared

final class DNSArtifactPublisherTests: XCTestCase {
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
    
    func testInitialPublicationAndManifest() throws {
        let publisher = DNSArtifactPublisher()
        let blocklistFeed = "||doubleclick.net^\n0.0.0.0 ad.doubleclick.net"
        let allowlistRules = ["apple.com", "developer.apple.com"]
        
        let manifest = try publisher.publish(
            blocklistSources: [blocklistFeed],
            allowlistRules: allowlistRules,
            baseAppGroupURL: tempAppGroupURL
        )
        
        XCTAssertEqual(manifest.generation, 1)
        XCTAssertEqual(manifest.blocklistCount, 2)
        XCTAssertEqual(manifest.allowlistCount, 2)
        
        // Verify current.json exists and points to 000001
        let currentPointerURL = DNSAppGroupPaths.currentPointerURL(base: tempAppGroupURL)!
        let currentData = try Data(contentsOf: currentPointerURL)
        let pointer = try JSONDecoder().decode(DNSCurrentPointer.self, from: currentData)
        XCTAssertEqual(pointer.activeGeneration, "000001")
        
        // Verify generation directory contents
        let gen1Dir = DNSAppGroupPaths.generationDirectory(generationName: "000001", base: tempAppGroupURL)!
        let blockURL = gen1Dir.appendingPathComponent(DNSArtifactFormat.blocklistFilename)
        let allowURL = gen1Dir.appendingPathComponent(DNSArtifactFormat.allowlistFilename)
        let manifestURL = gen1Dir.appendingPathComponent(DNSArtifactFormat.manifestFilename)
        
        XCTAssertTrue(fileManager.fileExists(atPath: blockURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: allowURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: manifestURL.path))
        
        // Verify SHA-256 match
        let blockData = try Data(contentsOf: blockURL)
        let computedBlockSHA = DNSGenerationManifest.computeSHA256(data: blockData)
        XCTAssertEqual(manifest.sha256Blocklist, computedBlockSHA)
    }
    
    func testSequentialGenerationsAndPruning() throws {
        let publisher = DNSArtifactPublisher()
        
        // Generation 1
        _ = try publisher.publish(
            blocklistSources: ["||site1.com^"],
            allowlistRules: [],
            baseAppGroupURL: tempAppGroupURL
        )
        
        // Generation 2
        _ = try publisher.publish(
            blocklistSources: ["||site2.com^"],
            allowlistRules: [],
            baseAppGroupURL: tempAppGroupURL
        )
        
        // Generation 3
        let manifest3 = try publisher.publish(
            blocklistSources: ["||site3.com^"],
            allowlistRules: [],
            baseAppGroupURL: tempAppGroupURL
        )
        
        XCTAssertEqual(manifest3.generation, 3)
        
        let currentPointerURL = DNSAppGroupPaths.currentPointerURL(base: tempAppGroupURL)!
        let currentData = try Data(contentsOf: currentPointerURL)
        let pointer = try JSONDecoder().decode(DNSCurrentPointer.self, from: currentData)
        XCTAssertEqual(pointer.activeGeneration, "000003")
        
        let generationsDir = DNSAppGroupPaths.generationsDirectory(base: tempAppGroupURL)!
        let contents = try fileManager.contentsOfDirectory(at: generationsDir, includingPropertiesForKeys: nil)
        let genNames = Set(contents.map { $0.lastPathComponent })
        
        // Pruning keeps active (000003) and previous (000002). 000001 should be pruned!
        XCTAssertTrue(genNames.contains("000003"))
        XCTAssertTrue(genNames.contains("000002"))
        XCTAssertFalse(genNames.contains("000001"))
    }
}
