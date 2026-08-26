// ADBLXTests/Features/Premium/Trial/TrialManagerTests.swift
import Foundation
import Testing
@testable import ADBLX

final class InMemoryTrialStore: TrialStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var record: TrialRecord?

    init(record: TrialRecord? = nil) {
        self.record = record
    }

    func loadRecord() -> TrialRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    func saveRecord(_ record: TrialRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        self.record = record
    }

    func deleteRecord() {
        lock.lock()
        defer { lock.unlock() }
        self.record = nil
    }
}

@Suite("TrialManager")
struct TrialManagerTests {
    @Test("Initial state before activation is .notStarted")
    func initialStateNotStarted() async {
        let store = InMemoryTrialStore()
        let manager = TrialManager(store: store)

        let status = await manager.status(at: Date())
        #expect(status == .notStarted)

        let entitlement = await manager.currentEntitlement(at: Date())
        #expect(entitlement == .free)
    }

    @Test("Explicit activateTrial starts 15-day countdown")
    func activateTrialStartsCountdown() async {
        let store = InMemoryTrialStore()
        let manager = TrialManager(store: store)
        let now = Date()

        let status = await manager.activateTrial(at: now)
        guard case .active(let expiresAt, let daysRemaining) = status else {
            Issue.record("Expected .active, got \(status)")
            return
        }

        #expect(daysRemaining == 15)
        #expect(abs(expiresAt.timeIntervalSince(now.addingTimeInterval(15 * 86400))) < 1.0)

        let entitlement = await manager.currentEntitlement(at: now)
        #expect(entitlement == .trial(expiresAt: expiresAt))
    }

    @Test("Re-activating an existing trial is idempotent and does not reset activation timestamp")
    func reactivationIsIdempotent() async {
        let store = InMemoryTrialStore()
        let manager = TrialManager(store: store)
        let day0 = Date()

        _ = await manager.activateTrial(at: day0)

        // Try activating again at day 5
        let day5 = day0.addingTimeInterval(5 * 86400)
        let status = await manager.activateTrial(at: day5)

        guard case .active(let expiresAt, let daysRemaining) = status else {
            Issue.record("Expected .active, got \(status)")
            return
        }

        // Must still expire 15 days from day0, not day5
        #expect(daysRemaining == 10)
        #expect(abs(expiresAt.timeIntervalSince(day0.addingTimeInterval(15 * 86400))) < 1.0)
    }

    @Test("Day 14 reports 1 day remaining, Day 15 reports expired")
    func countdownProgressionAndExpiry() async {
        let store = InMemoryTrialStore()
        let manager = TrialManager(store: store)
        let start = Date()

        _ = await manager.activateTrial(at: start)

        // Day 14 (14 days after start)
        let day14 = start.addingTimeInterval(14 * 86400)
        let status14 = await manager.status(at: day14)
        guard case .active(_, let daysRemaining14) = status14 else {
            Issue.record("Expected .active on day 14")
            return
        }
        #expect(daysRemaining14 == 1)

        // Day 15 + 1 second
        let day15 = start.addingTimeInterval(15 * 86400 + 1)
        let status15 = await manager.status(at: day15)
        #expect(status15 == .expired)

        let entitlement = await manager.currentEntitlement(at: day15)
        #expect(entitlement == .free)
    }

    @Test("Clock rollback while active cannot extend trial or increase days remaining")
    func clockRollbackWhileActiveIsResisted() async {
        let store = InMemoryTrialStore()
        let manager = TrialManager(store: store)
        let start = Date()

        _ = await manager.activateTrial(at: start)

        // App is opened at Day 14 -> persists lastObservedDate = Day 14
        let day14 = start.addingTimeInterval(14 * 86400)
        let status14 = await manager.status(at: day14)
        guard case .active(_, let days14) = status14 else {
            Issue.record("Expected .active on Day 14")
            return
        }
        #expect(days14 == 1)

        // User sets device clock back to Day 5
        let day5 = start.addingTimeInterval(5 * 86400)
        let statusRollback = await manager.status(at: day5)

        guard case .active(_, let daysRollback) = statusRollback else {
            Issue.record("Expected .active after rollback")
            return
        }

        // Monotonic effectiveDate (Day 14) prevents daysRemaining from increasing to 10
        #expect(daysRollback == 1)
    }

    @Test("Irreversible expiry: setting clock back after expiration remains strictly .expired")
    func irreversibleExpiryAfterRollback() async {
        let store = InMemoryTrialStore()
        let manager = TrialManager(store: store)
        let start = Date()

        _ = await manager.activateTrial(at: start)

        // Advance past expiration
        let pastExpiry = start.addingTimeInterval(16 * 86400)
        let expiredStatus = await manager.status(at: pastExpiry)
        #expect(expiredStatus == .expired)

        // Set device clock back to day 2
        let day2 = start.addingTimeInterval(2 * 86400)
        let statusAfterRollback = await manager.status(at: day2)
        #expect(statusAfterRollback == .expired)

        let entitlement = await manager.currentEntitlement(at: day2)
        #expect(entitlement == .free)
    }
}
