import XCTest
@testable import ADBLX
import ADBLXShared

final class WebExtensionEntitlementPublisherTests: XCTestCase {
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
    
    func testPublishPremiumActive() throws {
        let publisher = WebExtensionEntitlementPublisher()
        try publisher.publish(isPremium: true, baseAppGroupURL: tempAppGroupURL)
        
        let entitlementURL = WebExtensionAppGroupPaths.entitlementFileURL(base: tempAppGroupURL)!
        XCTAssertTrue(fileManager.fileExists(atPath: entitlementURL.path))
        
        let data = try Data(contentsOf: entitlementURL)
        let record = try JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: data)
        XCTAssertEqual(record.state, .premiumActive)
        XCTAssertGreaterThan(record.updatedAt, 0)
    }
    
    func testPublishWritesValidUntil() throws {
        let publisher = WebExtensionEntitlementPublisher()
        let until = Date(timeIntervalSince1970: 2_000_000_000)
        try publisher.publish(isPremium: true, validUntil: until, baseAppGroupURL: tempAppGroupURL)
        let url = WebExtensionAppGroupPaths.entitlementFileURL(base: tempAppGroupURL)!
        let record = try JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: Data(contentsOf: url))
        XCTAssertEqual(record.validUntil, 2_000_000_000)
    }

    func testPublishFree() throws {
        let publisher = WebExtensionEntitlementPublisher()
        try publisher.publish(isPremium: false, baseAppGroupURL: tempAppGroupURL)
        
        let entitlementURL = WebExtensionAppGroupPaths.entitlementFileURL(base: tempAppGroupURL)!
        XCTAssertTrue(fileManager.fileExists(atPath: entitlementURL.path))
        
        let data = try Data(contentsOf: entitlementURL)
        let record = try JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: data)
        XCTAssertEqual(record.state, .free)
        XCTAssertGreaterThan(record.updatedAt, 0)
    }
    
    func testOverwriteEntitlementStateAtomically() throws {
        let publisher = WebExtensionEntitlementPublisher()
        
        // 1. Publish premiumActive
        try publisher.publish(isPremium: true, baseAppGroupURL: tempAppGroupURL)
        let entitlementURL = WebExtensionAppGroupPaths.entitlementFileURL(base: tempAppGroupURL)!
        var data = try Data(contentsOf: entitlementURL)
        var record = try JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: data)
        XCTAssertEqual(record.state, .premiumActive)
        
        // 2. Overwrite with free
        try publisher.publish(isPremium: false, baseAppGroupURL: tempAppGroupURL)
        data = try Data(contentsOf: entitlementURL)
        record = try JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: data)
        XCTAssertEqual(record.state, .free)
    }
}
