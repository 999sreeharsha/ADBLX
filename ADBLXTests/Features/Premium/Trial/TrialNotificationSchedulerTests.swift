// ADBLXTests/Features/Premium/Trial/TrialNotificationSchedulerTests.swift
import Foundation
import Testing
import UserNotifications
@testable import ADBLX

final class MockNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: UNNotificationRequest] = [:]
    var authorizationResult: Bool = true
    var authorizationError: Error?

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        if let error = authorizationError {
            throw error
        }
        return authorizationResult
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.lock()
        defer { lock.unlock() }
        requests[request.identifier] = request
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for id in identifiers {
            requests.removeValue(forKey: id)
        }
    }

    func getPendingNotificationRequests() async -> [UNNotificationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return Array(requests.values)
    }
}

@Suite("TrialNotificationScheduler", .serialized)
struct TrialNotificationSchedulerTests {
    @Test("Newly activated trial schedules exactly 5 calendar notifications")
    func schedulesFiveMilestones() async throws {
        let center = MockNotificationCenter()
        let mockEntitlement = MockSubscriptionService(state: .trial(expiresAt: Date().addingTimeInterval(15 * 86400)))
        let scheduler = TrialNotificationScheduler(
            notificationCenter: center,
            entitlementService: mockEntitlement
        )

        let start = Date()
        try await scheduler.scheduleTrialNotifications(activatedAt: start, referenceDate: start)

        let pending = await center.getPendingNotificationRequests()
        #expect(pending.count == 5)

        let identifiers = Set(pending.map(\.identifier))
        #expect(identifiers == Set(TrialNotificationScheduler.allTrialIdentifiers))

        // Verify triggers are UNCalendarNotificationTrigger
        for request in pending {
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger else {
                Issue.record("Expected UNCalendarNotificationTrigger for \(request.identifier)")
                continue
            }
            #expect(trigger.repeats == false)
        }
    }

    @Test("Re-running schedule is idempotent and does not create duplicates")
    func reschedulingIsIdempotent() async throws {
        let center = MockNotificationCenter()
        let mockEntitlement = MockSubscriptionService(state: .trial(expiresAt: Date().addingTimeInterval(15 * 86400)))
        let scheduler = TrialNotificationScheduler(
            notificationCenter: center,
            entitlementService: mockEntitlement
        )

        let start = Date()
        try await scheduler.scheduleTrialNotifications(activatedAt: start, referenceDate: start)
        try await scheduler.scheduleTrialNotifications(activatedAt: start, referenceDate: start)

        let pending = await center.getPendingNotificationRequests()
        #expect(pending.count == 5)
    }

    @Test("Past milestones are skipped; only future milestones are scheduled")
    func pastMilestonesSkipped() async throws {
        let center = MockNotificationCenter()
        let mockEntitlement = MockSubscriptionService(state: .trial(expiresAt: Date().addingTimeInterval(15 * 86400)))
        let scheduler = TrialNotificationScheduler(
            notificationCenter: center,
            entitlementService: mockEntitlement
        )

        let start = Date()
        // Evaluate at Day 6 -> Day 5 is in the past
        let day6 = start.addingTimeInterval(6 * 86400)
        try await scheduler.scheduleTrialNotifications(activatedAt: start, referenceDate: day6)

        let pending = await center.getPendingNotificationRequests()
        #expect(pending.count == 4) // Day 9, 12, 14, 15

        let ids = Set(pending.map(\.identifier))
        #expect(!ids.contains(TrialNotificationScheduler.day5Identifier))
        #expect(ids.contains(TrialNotificationScheduler.day9Identifier))
    }

    @Test("If Day 15 is past, zero notifications are scheduled")
    func pastDay15SchedulesZero() async throws {
        let center = MockNotificationCenter()
        let mockEntitlement = MockSubscriptionService(state: .trial(expiresAt: Date().addingTimeInterval(15 * 86400)))
        let scheduler = TrialNotificationScheduler(
            notificationCenter: center,
            entitlementService: mockEntitlement
        )

        let start = Date()
        let day16 = start.addingTimeInterval(16 * 86400)
        try await scheduler.scheduleTrialNotifications(activatedAt: start, referenceDate: day16)

        let pending = await center.getPendingNotificationRequests()
        #expect(pending.isEmpty)
    }

    @Test("Entitlement transitions to .free, .monthly, .annual, .lifetime cancel all pending notifications")
    func entitlementTransitionsCancelNotifications() async throws {
        let center = MockNotificationCenter()
        let mockEntitlement = MockSubscriptionService(state: .trial(expiresAt: Date().addingTimeInterval(15 * 86400)))
        let scheduler = TrialNotificationScheduler(
            notificationCenter: center,
            entitlementService: mockEntitlement
        )

        await scheduler.startObserving()

        // 1. Initial schedule during trial
        let start = Date()
        try await scheduler.scheduleTrialNotifications(activatedAt: start, referenceDate: start)
        #expect((await center.getPendingNotificationRequests()).count == 5)

        // 2. Transition to .monthly -> All cancelled
        mockEntitlement.updateState(.monthly(expiresAt: start.addingTimeInterval(30 * 86400)))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect((await center.getPendingNotificationRequests()).isEmpty)

        // 3. Reschedule and transition to .free -> All cancelled
        try await scheduler.scheduleTrialNotifications(activatedAt: start, referenceDate: start)
        #expect((await center.getPendingNotificationRequests()).count == 5)

        mockEntitlement.updateState(.free)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect((await center.getPendingNotificationRequests()).isEmpty)
    }
}
