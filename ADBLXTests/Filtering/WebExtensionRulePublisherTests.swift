import XCTest
@testable import ADBLX
import ADBLXShared

final class WebExtensionRulePublisherTests: XCTestCase {
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
    
    private func validSampleRulesJSON() -> Data {
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
              "disabledDomains": []
            },
            "selectors": {
              "playerContainers": ["#movie_player"],
              "adStateClasses": ["ad-showing"],
              "skipButtons": [".ytp-ad-skip-button"],
              "adBadges": [".ytp-ad-text"],
              "cosmeticHideTargets": [".ytp-ad-player-overlay"]
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
        """.data(using: .utf8)!
    }
    
    func testInitialPublicationAndManifest() throws {
        let publisher = WebExtensionRulePublisher()
        let rulesData = validSampleRulesJSON()
        
        let manifest = try publisher.publish(
            rulesData: rulesData,
            baseAppGroupURL: tempAppGroupURL
        )
        
        XCTAssertEqual(manifest.generation, 1)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.rulesSizeBytes, rulesData.count)
        
        // Verify current.json exists and points to 000001
        let currentPointerURL = WebExtensionAppGroupPaths.currentPointerURL(base: tempAppGroupURL)!
        let currentData = try Data(contentsOf: currentPointerURL)
        let pointer = try JSONDecoder().decode(WebExtensionCurrentPointer.self, from: currentData)
        XCTAssertEqual(pointer.activeGeneration, "000001")
        
        // Verify generation directory contents
        let gen1Dir = WebExtensionAppGroupPaths.generationDirectory(generationName: "000001", base: tempAppGroupURL)!
        let rulesFileURL = gen1Dir.appendingPathComponent(WebExtensionArtifactFormat.rulesFilename)
        let manifestFileURL = gen1Dir.appendingPathComponent(WebExtensionArtifactFormat.manifestFilename)
        
        XCTAssertTrue(fileManager.fileExists(atPath: rulesFileURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: manifestFileURL.path))
        
        // Verify SHA-256 matches
        let readRulesData = try Data(contentsOf: rulesFileURL)
        let computedSHA = WebExtensionGenerationManifest.computeSHA256(data: readRulesData)
        XCTAssertEqual(manifest.sha256Rules, computedSHA)
    }
    
    func testSequentialGenerationsAndPruning() throws {
        let publisher = WebExtensionRulePublisher()
        let rulesData = validSampleRulesJSON()
        
        // Publish Gen 1
        _ = try publisher.publish(rulesData: rulesData, baseAppGroupURL: tempAppGroupURL)
        let gen1 = WebExtensionAppGroupPaths.generationDirectory(generationName: "000001", base: tempAppGroupURL)!
        XCTAssertTrue(fileManager.fileExists(atPath: gen1.path))
        
        // Publish Gen 2
        _ = try publisher.publish(rulesData: rulesData, baseAppGroupURL: tempAppGroupURL)
        let gen2 = WebExtensionAppGroupPaths.generationDirectory(generationName: "000002", base: tempAppGroupURL)!
        XCTAssertTrue(fileManager.fileExists(atPath: gen1.path)) // Active - 1 retained
        XCTAssertTrue(fileManager.fileExists(atPath: gen2.path))
        
        // Publish Gen 3
        _ = try publisher.publish(rulesData: rulesData, baseAppGroupURL: tempAppGroupURL)
        let gen3 = WebExtensionAppGroupPaths.generationDirectory(generationName: "000003", base: tempAppGroupURL)!
        XCTAssertFalse(fileManager.fileExists(atPath: gen1.path)) // Gen 1 pruned!
        XCTAssertTrue(fileManager.fileExists(atPath: gen2.path))  // Gen 2 retained (1 prior)
        XCTAssertTrue(fileManager.fileExists(atPath: gen3.path))  // Gen 3 active
        
        let pointer = try WebExtensionCurrentPointer.readCurrent(appGroupBaseDirectory: tempAppGroupURL)
        XCTAssertEqual(pointer.activeGeneration, "000003")
    }
    
    func testValidationFailureLeavesExistingCurrentPointerByteForByteUnchanged() throws {
        let publisher = WebExtensionRulePublisher()
        let validRules = validSampleRulesJSON()
        
        // 1. Publish valid Gen 1
        _ = try publisher.publish(rulesData: validRules, baseAppGroupURL: tempAppGroupURL)
        let currentPointerURL = WebExtensionAppGroupPaths.currentPointerURL(base: tempAppGroupURL)!
        let rawPointerBytesBefore = try Data(contentsOf: currentPointerURL)
        
        // 2. Attempt publishing invalid payload
        let invalidData = "invalid non-json payload".data(using: .utf8)!
        XCTAssertThrowsError(try publisher.publish(rulesData: invalidData, baseAppGroupURL: tempAppGroupURL))
        
        // 3. Verify current.json is byte-for-byte identical
        let rawPointerBytesAfter = try Data(contentsOf: currentPointerURL)
        XCTAssertEqual(rawPointerBytesBefore, rawPointerBytesAfter)
        
        // 4. Verify no new generation directory 000002 was created
        let gen2Dir = WebExtensionAppGroupPaths.generationDirectory(generationName: "000002", base: tempAppGroupURL)!
        XCTAssertFalse(fileManager.fileExists(atPath: gen2Dir.path))
        
        // Verify staging was cleaned up
        let stagingDir = WebExtensionAppGroupPaths.stagingDirectory(base: tempAppGroupURL)!
        XCTAssertFalse(fileManager.fileExists(atPath: stagingDir.path))
    }
    
    func testSuccessfulReplacementLeavesPriorGenerationAvailable() throws {
        let publisher = WebExtensionRulePublisher()
        let rulesData = validSampleRulesJSON()
        
        // Publish Gen 1
        let manifest1 = try publisher.publish(rulesData: rulesData, baseAppGroupURL: tempAppGroupURL)
        XCTAssertEqual(manifest1.generation, 1)
        
        // Publish Gen 2
        let manifest2 = try publisher.publish(rulesData: rulesData, baseAppGroupURL: tempAppGroupURL)
        XCTAssertEqual(manifest2.generation, 2)
        
        // Current pointer resolves to Gen 2
        let pointer = try WebExtensionCurrentPointer.readCurrent(appGroupBaseDirectory: tempAppGroupURL)
        XCTAssertEqual(pointer.activeGeneration, "000002")
        
        // Gen 1 remains physically on disk and readable
        let gen1Dir = WebExtensionAppGroupPaths.generationDirectory(generationName: "000001", base: tempAppGroupURL)!
        let gen1ManifestURL = gen1Dir.appendingPathComponent(WebExtensionArtifactFormat.manifestFilename)
        XCTAssertTrue(fileManager.fileExists(atPath: gen1ManifestURL.path))
        
        let gen1ManifestData = try Data(contentsOf: gen1ManifestURL)
        let gen1Manifest = try JSONDecoder().decode(WebExtensionGenerationManifest.self, from: gen1ManifestData)
        XCTAssertEqual(gen1Manifest.generation, 1)
    }
}
