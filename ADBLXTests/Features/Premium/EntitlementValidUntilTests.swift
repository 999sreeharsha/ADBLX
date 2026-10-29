import Foundation
import Testing
@testable import ADBLX

@Suite("EntitlementState.validUntil")
struct EntitlementValidUntilTests {
    private let end = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("free has no validity window")
    func free() { #expect(EntitlementState.free.validUntil == nil) }

    @Test("lifetime never expires")
    func lifetime() { #expect(EntitlementState.lifetime.validUntil == nil) }

    @Test("trial ends exactly at expiresAt — no slack")
    func trial() { #expect(EntitlementState.trial(expiresAt: end).validUntil == end) }

    @Test("monthly gets exactly 7 days of slack")
    func monthly() {
        #expect(EntitlementState.monthly(expiresAt: end).validUntil == end.addingTimeInterval(7 * 86400))
    }

    @Test("annual gets exactly 7 days of slack")
    func annual() {
        #expect(EntitlementState.annual(expiresAt: end).validUntil == end.addingTimeInterval(7 * 86400))
    }
}
