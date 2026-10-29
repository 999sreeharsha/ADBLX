import XCTest
@testable import ADBLXShared

final class TunnelEntitlementGuardTests: XCTestCase {
    private func makeBase(_ record: WebExtensionPersistedEntitlement?) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = try XCTUnwrap(WebExtensionAppGroupPaths.webExtensionRootDirectory(base: base))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let record {
            let url = try XCTUnwrap(WebExtensionAppGroupPaths.entitlementFileURL(base: base))
            try JSONEncoder().encode(record).write(to: url)
        }
        return base
    }

    func testAllowedBeforeValidUntil() throws {
        let base = try makeBase(.init(state: .premiumActive, updatedAt: 0, validUntil: 1000))
        XCTAssertEqual(TunnelEntitlementGuard.check(baseAppGroupURL: base, now: Date(timeIntervalSince1970: 999)), .allowed)
    }

    func testDeniedAtAndAfterValidUntil() throws {
        let base = try makeBase(.init(state: .premiumActive, updatedAt: 0, validUntil: 1000))
        XCTAssertEqual(TunnelEntitlementGuard.check(baseAppGroupURL: base, now: Date(timeIntervalSince1970: 1000)), .deniedExpired)
        XCTAssertEqual(TunnelEntitlementGuard.check(baseAppGroupURL: base, now: Date(timeIntervalSince1970: 5000)), .deniedExpired)
    }

    func testLifetimeAllowedForever() throws {
        let base = try makeBase(.init(state: .premiumActive, updatedAt: 0))
        XCTAssertEqual(TunnelEntitlementGuard.check(baseAppGroupURL: base, now: Date(timeIntervalSince1970: 9e9)), .allowed)
    }

    func testMissingFileIsAllowedBecauseTheAppAlreadyGatedStart() throws {
        let base = try makeBase(nil)
        XCTAssertEqual(TunnelEntitlementGuard.check(baseAppGroupURL: base, now: Date()), .allowed)
        XCTAssertEqual(TunnelEntitlementGuard.check(baseAppGroupURL: nil, now: Date()), .allowed)
    }
}
