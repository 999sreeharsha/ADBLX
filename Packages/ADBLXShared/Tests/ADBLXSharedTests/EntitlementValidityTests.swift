import XCTest
@testable import ADBLXShared

final class EntitlementValidityTests: XCTestCase {
    private func makeBase(_ record: WebExtensionPersistedEntitlement) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = try XCTUnwrap(WebExtensionAppGroupPaths.webExtensionRootDirectory(base: base))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try XCTUnwrap(WebExtensionAppGroupPaths.entitlementFileURL(base: base))
        try JSONEncoder().encode(record).write(to: url)
        return base
    }

    func testLegacyRecordWithoutValidUntilDecodes() throws {
        let legacy = Data(#"{"state":"premiumActive","updatedAt":1.0}"#.utf8)
        let decoded = try JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: legacy)
        XCTAssertNil(decoded.validUntil)
        XCTAssertFalse(decoded.isExpired(at: Date(timeIntervalSince1970: 9e9)))
    }

    func testIsExpiredBoundary() {
        let rec = WebExtensionPersistedEntitlement(state: .premiumActive, updatedAt: 0, validUntil: 1000)
        XCTAssertFalse(rec.isExpired(at: Date(timeIntervalSince1970: 999)))
        XCTAssertTrue(rec.isExpired(at: Date(timeIntervalSince1970: 1000)))
        XCTAssertTrue(rec.isExpired(at: Date(timeIntervalSince1970: 1001)))
    }

    func testCheckVersionReportsPremiumBeforeValidUntilAndSurfacesIt() throws {
        let base = try makeBase(.init(state: .premiumActive, updatedAt: 0, validUntil: 1000))
        let proc = SafariWebExtensionBridgeProcessor(now: { Date(timeIntervalSince1970: 500) })
        let res = proc.processMessage(message: ["type": "checkVersion"], baseAppGroupURL: base)
        XCTAssertEqual(res["entitlementState"] as? String, "premiumActive")
        XCTAssertEqual(res["validUntilMs"] as? Int, 1_000_000)
    }

    func testCheckVersionReportsFreeAfterValidUntil() throws {
        let base = try makeBase(.init(state: .premiumActive, updatedAt: 0, validUntil: 1000))
        let proc = SafariWebExtensionBridgeProcessor(now: { Date(timeIntervalSince1970: 1000) })
        let res = proc.processMessage(message: ["type": "checkVersion"], baseAppGroupURL: base)
        XCTAssertEqual(res["entitlementState"] as? String, "free")
    }

    func testNilValidUntilNeverExpires() throws {
        let base = try makeBase(.init(state: .premiumActive, updatedAt: 0))
        let proc = SafariWebExtensionBridgeProcessor(now: { Date(timeIntervalSince1970: 9e9) })
        let res = proc.processMessage(message: ["type": "checkVersion"], baseAppGroupURL: base)
        XCTAssertEqual(res["entitlementState"] as? String, "premiumActive")
        XCTAssertNil(res["validUntilMs"])
    }
}
