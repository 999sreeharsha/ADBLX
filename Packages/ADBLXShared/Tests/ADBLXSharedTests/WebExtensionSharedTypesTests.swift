import XCTest
@testable import ADBLXShared

final class WebExtensionSharedTypesTests: XCTestCase {
    
    // MARK: - App Group Paths Tests
    
    func testAppGroupPathsConstruction() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        
        let root = WebExtensionAppGroupPaths.webExtensionRootDirectory(base: tempBase)
        XCTAssertEqual(root?.lastPathComponent, "WebExtension")
        
        let genDir = WebExtensionAppGroupPaths.generationsDirectory(base: tempBase)
        XCTAssertEqual(genDir?.lastPathComponent, "generations")
        XCTAssertEqual(genDir?.deletingLastPathComponent().lastPathComponent, "WebExtension")
        
        let stagingDir = WebExtensionAppGroupPaths.stagingDirectory(base: tempBase)
        XCTAssertEqual(stagingDir?.lastPathComponent, "staging")
        
        let pointerURL = WebExtensionAppGroupPaths.currentPointerURL(base: tempBase)
        XCTAssertEqual(pointerURL?.lastPathComponent, "current.json")
        
        let entitlementURL = WebExtensionAppGroupPaths.entitlementFileURL(base: tempBase)
        XCTAssertEqual(entitlementURL?.lastPathComponent, "entitlement.json")
        
        let gen1Dir = WebExtensionAppGroupPaths.generationDirectory(generationNumber: 1, base: tempBase)
        XCTAssertEqual(gen1Dir?.lastPathComponent, "000001")
        
        let gen42Dir = WebExtensionAppGroupPaths.generationDirectory(generationName: "000042", base: tempBase)
        XCTAssertEqual(gen42Dir?.lastPathComponent, "000042")
    }
    
    // MARK: - Artifact Format Constants Tests
    
    func testArtifactFormatConstants() {
        XCTAssertEqual(WebExtensionArtifactFormat.currentSchemaVersion, 1)
        XCTAssertEqual(WebExtensionArtifactFormat.rulesFilename, "rules.json")
        XCTAssertEqual(WebExtensionArtifactFormat.manifestFilename, "manifest.json")
        XCTAssertEqual(WebExtensionArtifactFormat.currentPointerFilename, "current.json")
        XCTAssertEqual(WebExtensionArtifactFormat.entitlementFilename, "entitlement.json")
        XCTAssertTrue(WebExtensionArtifactFormat.allowedDomains.contains("m.youtube.com"))
        XCTAssertTrue(WebExtensionArtifactFormat.allowedDomains.contains("www.youtube.com"))
        XCTAssertEqual(WebExtensionArtifactFormat.allowedDomains.count, 2)
    }
    
    // MARK: - Generation Manifest & Pointer Tests
    
    func testManifestAndPointerCodable() throws {
        let manifest = WebExtensionGenerationManifest(
            schemaVersion: 1,
            generation: 42,
            publishedAt: 123456789.0,
            sha256Rules: "abcdef123456",
            rulesSizeBytes: 1024
        )
        
        let encodedManifest = try JSONEncoder().encode(manifest)
        let decodedManifest = try JSONDecoder().decode(WebExtensionGenerationManifest.self, from: encodedManifest)
        XCTAssertEqual(manifest, decodedManifest)
        
        let pointer = WebExtensionCurrentPointer(generationNumber: 42, publishedAt: 123456789.0)
        XCTAssertEqual(pointer.activeGeneration, "000042")
        
        let encodedPointer = try JSONEncoder().encode(pointer)
        let decodedPointer = try JSONDecoder().decode(WebExtensionCurrentPointer.self, from: encodedPointer)
        XCTAssertEqual(pointer, decodedPointer)
    }
    
    func testComputeSHA256() {
        let testData = "test rules payload".data(using: .utf8)!
        let sha = WebExtensionGenerationManifest.computeSHA256(data: testData)
        XCTAssertFalse(sha.isEmpty)
        XCTAssertEqual(sha.count, 64) // SHA-256 hex string length
    }
    
    func testReadCurrentManifestAndPointer() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        
        guard let _ = WebExtensionAppGroupPaths.webExtensionRootDirectory(base: tempBase),
              let genDir = WebExtensionAppGroupPaths.generationDirectory(generationNumber: 5, base: tempBase),
              let pointerURL = WebExtensionAppGroupPaths.currentPointerURL(base: tempBase) else {
            XCTFail("Failed to resolve paths")
            return
        }
        
        try FileManager.default.createDirectory(at: genDir, withIntermediateDirectories: true)
        
        let manifest = WebExtensionGenerationManifest(
            generation: 5,
            publishedAt: 1000.0,
            sha256Rules: "mocksha256",
            rulesSizeBytes: 2048
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: genDir.appendingPathComponent(WebExtensionArtifactFormat.manifestFilename))
        
        let pointer = WebExtensionCurrentPointer(generationNumber: 5, publishedAt: 1000.0)
        let pointerData = try JSONEncoder().encode(pointer)
        try pointerData.write(to: pointerURL)
        
        let readPointer = try WebExtensionCurrentPointer.readCurrent(appGroupBaseDirectory: tempBase)
        XCTAssertEqual(readPointer.activeGeneration, "000005")
        
        let readManifest = try WebExtensionGenerationManifest.readCurrentManifest(appGroupBaseDirectory: tempBase)
        XCTAssertEqual(readManifest.generation, 5)
        XCTAssertEqual(readManifest.sha256Rules, "mocksha256")
    }
    
    // MARK: - Bridge Messages Tests
    
    func testCheckVersionResponseSerialization() throws {
        let response = WebExtensionCheckVersionResponse(
            generation: 42,
            generationStatus: .ok,
            entitlementState: .premiumActive,
            checkedAt: 9999.0
        )
        
        let dict = response.toDictionary()
        XCTAssertEqual(dict["generation"] as? Int, 42)
        XCTAssertEqual(dict["generationStatus"] as? String, "ok")
        XCTAssertEqual(dict["entitlementState"] as? String, "premiumActive")
        XCTAssertEqual(dict["checkedAt"] as? TimeInterval, 9999.0)
        
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(WebExtensionCheckVersionResponse.self, from: data)
        XCTAssertEqual(response, decoded)
    }
    
    func testFetchGenerationResponseSerialization() throws {
        let mockRulesJSON = "{\"schemaVersion\":1,\"enabled\":true}"
        let response = WebExtensionFetchGenerationResponse(
            generation: 42,
            generationStatus: .ok,
            rulesJSON: mockRulesJSON
        )
        
        let dict = response.toDictionary()
        XCTAssertEqual(dict["generation"] as? Int, 42)
        XCTAssertEqual(dict["generationStatus"] as? String, "ok")
        XCTAssertNil(dict["checksum"], "SEC-18: the response carries no checksum")
        XCTAssertNotNil(dict["rules"])
        
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(WebExtensionFetchGenerationResponse.self, from: data)
        XCTAssertEqual(response, decoded)
    }
    
    func testPersistedEntitlementCodable() throws {
        let entitlement = WebExtensionPersistedEntitlement(
            state: .premiumActive,
            updatedAt: 5555.0
        )
        
        let data = try JSONEncoder().encode(entitlement)
        let decoded = try JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: data)
        XCTAssertEqual(entitlement, decoded)
        XCTAssertEqual(decoded.state, .premiumActive)
    }
}
