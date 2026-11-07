import XCTest
@testable import ADBLX
import ADBLXShared

final class SafariWebExtensionHandlerTests: XCTestCase {
    private var tempAppGroupURL: URL!
    private let fileManager = FileManager.default
    private let processor = SafariWebExtensionBridgeProcessor()
    
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
    
    private func setupMockGeneration(genNumber: UInt64, rulesJSON: String) throws {
        guard let genDir = WebExtensionAppGroupPaths.generationDirectory(generationNumber: genNumber, base: tempAppGroupURL),
              let pointerURL = WebExtensionAppGroupPaths.currentPointerURL(base: tempAppGroupURL) else {
            XCTFail("Failed to resolve paths")
            return
        }
        
        try fileManager.createDirectory(at: genDir, withIntermediateDirectories: true)
        
        let rulesData = rulesJSON.data(using: .utf8)!
        let rulesURL = genDir.appendingPathComponent(WebExtensionArtifactFormat.rulesFilename)
        try rulesData.write(to: rulesURL)
        
        let sha = WebExtensionGenerationManifest.computeSHA256(data: rulesData)
        let manifest = WebExtensionGenerationManifest(
            generation: genNumber,
            publishedAt: 1000.0,
            sha256Rules: sha,
            rulesSizeBytes: rulesData.count
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: genDir.appendingPathComponent(WebExtensionArtifactFormat.manifestFilename))
        
        let pointer = WebExtensionCurrentPointer(generationNumber: genNumber, publishedAt: 1000.0)
        let pointerData = try JSONEncoder().encode(pointer)
        try pointerData.write(to: pointerURL)
    }
    
    private func setupMockEntitlement(state: WebExtensionPersistedEntitlementState) throws {
        guard let entitlementURL = WebExtensionAppGroupPaths.entitlementFileURL(base: tempAppGroupURL) else {
            XCTFail("Failed to resolve entitlement URL")
            return
        }
        
        let root = entitlementURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        
        let record = WebExtensionPersistedEntitlement(state: state, updatedAt: 2000.0)
        let data = try JSONEncoder().encode(record)
        try data.write(to: entitlementURL)
    }
    
    // MARK: - checkVersion Tests
    
    func testCheckVersionWithValidGenerationAndPremiumActive() throws {
        try setupMockGeneration(genNumber: 42, rulesJSON: "{\"schemaVersion\":1}")
        try setupMockEntitlement(state: .premiumActive)
        
        let message = ["type": "checkVersion"]
        let response = processor.processMessage(message: message, baseAppGroupURL: tempAppGroupURL)
        
        XCTAssertEqual(response["generation"] as? Int, 42)
        XCTAssertEqual(response["generationStatus"] as? String, "ok")
        XCTAssertEqual(response["entitlementState"] as? String, "premiumActive")
        XCTAssertNotNil(response["checkedAt"])
    }
    
    func testCheckVersionWithValidGenerationAndFreeEntitlement() throws {
        try setupMockGeneration(genNumber: 7, rulesJSON: "{\"schemaVersion\":1}")
        try setupMockEntitlement(state: .free)
        
        let message = ["type": "checkVersion"]
        let response = processor.processMessage(message: message, baseAppGroupURL: tempAppGroupURL)
        
        XCTAssertEqual(response["generation"] as? Int, 7)
        XCTAssertEqual(response["generationStatus"] as? String, "ok")
        XCTAssertEqual(response["entitlementState"] as? String, "free")
    }
    
    func testCheckVersionWhenEntitlementMissingFailsClosedIndependently() throws {
        try setupMockGeneration(genNumber: 10, rulesJSON: "{\"schemaVersion\":1}")
        // entitlement.json is NOT created
        
        let message = ["type": "checkVersion"]
        let response = processor.processMessage(message: message, baseAppGroupURL: tempAppGroupURL)
        
        XCTAssertEqual(response["generation"] as? Int, 10)
        XCTAssertEqual(response["generationStatus"] as? String, "ok")
        XCTAssertEqual(response["entitlementState"] as? String, "unavailable") // Fails closed!
    }
    
    func testCheckVersionWhenGenerationMissingMaintainsEntitlementState() throws {
        // current.json is NOT created
        try setupMockEntitlement(state: .premiumActive)
        
        let message = ["type": "checkVersion"]
        let response = processor.processMessage(message: message, baseAppGroupURL: tempAppGroupURL)
        
        XCTAssertEqual(response["generation"] as? Int, 0)
        XCTAssertEqual(response["generationStatus"] as? String, "unavailable")
        XCTAssertEqual(response["entitlementState"] as? String, "premiumActive")
    }
    
    // MARK: - fetchGeneration Tests
    
    func testFetchGenerationSuccess() throws {
        let sampleRules = "{\"schemaVersion\":1,\"youtube\":{\"enabled\":true}}"
        try setupMockGeneration(genNumber: 5, rulesJSON: sampleRules)
        
        let message: [String: Any] = ["type": "fetchGeneration", "generation": 5]
        let response = processor.processMessage(message: message, baseAppGroupURL: tempAppGroupURL)
        
        XCTAssertEqual(response["generation"] as? Int, 5)
        XCTAssertEqual(response["generationStatus"] as? String, "ok")
        XCTAssertNotNil(response["rules"])
        // SEC-18: the rules' checksum sat beside them in the App Group, so verifying it protected nothing.
        XCTAssertNil(response["checksum"])
    }
    
    func testFetchGenerationNonExistentReturnsUnavailable() throws {
        let message: [String: Any] = ["type": "fetchGeneration", "generation": 999]
        let response = processor.processMessage(message: message, baseAppGroupURL: tempAppGroupURL)
        
        XCTAssertEqual(response["generation"] as? Int, 999)
        XCTAssertEqual(response["generationStatus"] as? String, "unavailable")
        XCTAssertNil(response["rules"])
    }
    
    // MARK: - Malformed Message Tests
    
    func testMalformedMessageReturnsStructuredError() {
        let nilMessage: [String: Any]? = nil
        let responseNil = processor.processMessage(message: nilMessage, baseAppGroupURL: tempAppGroupURL)
        XCTAssertNotNil(responseNil["error"])
        
        let responseUnknownType = processor.processMessage(message: ["type": "unknownAction"], baseAppGroupURL: tempAppGroupURL)
        XCTAssertNotNil(responseUnknownType["error"])
        
        let responseMissingGen = processor.processMessage(message: ["type": "fetchGeneration"], baseAppGroupURL: tempAppGroupURL)
        XCTAssertNotNil(responseMissingGen["error"])
    }
}
