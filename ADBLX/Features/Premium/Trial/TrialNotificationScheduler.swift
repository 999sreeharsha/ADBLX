// ADBLX/Features/Premium/Trial/TrialNotificationScheduler.swift
import Foundation
import UserNotifications
import os

public protocol TrialNotificationSchedulerProtocol: Sendable {
    func requestAuthorization() async throws -> Bool
    func scheduleTrialNotifications(activatedAt: Date, referenceDate: Date) async throws
    func cancelPendingTrialNotifications() async
}

public extension TrialNotificationSchedulerProtocol {
    func scheduleTrialNotifications(activatedAt: Date) async throws {
        try await scheduleTrialNotifications(activatedAt: activatedAt, referenceDate: Date())
    }
}

public actor TrialNotificationScheduler: TrialNotificationSchedulerProtocol {
    public static let day5Identifier = "com.ADBLX.trial.day5"
    public static let day9Identifier = "com.ADBLX.trial.day9"
    public static let day12Identifier = "com.ADBLX.trial.day12"
    public static let day14Identifier = "com.ADBLX.trial.day14"
    public static let day15Identifier = "com.ADBLX.trial.day15"

    public static let allTrialIdentifiers = [
        day5Identifier,
        day9Identifier,
        day12Identifier,
        day14Identifier,
        day15Identifier
    ]

    private struct Milestone {
        let identifier: String
        let dayOffset: Int
        let title: String
        let body: String
    }

    private static let milestones: [Milestone] = [
        Milestone(
            identifier: day5Identifier,
            dayOffset: 5,
            title: "ADBLX Premium Trial",
            body: "You have 10 days remaining in your 15-day free trial."
        ),
        Milestone(
            identifier: day9Identifier,
            dayOffset: 9,
            title: "ADBLX Premium Trial",
            body: "You have 6 days remaining in your 15-day free trial."
        ),
        Milestone(
            identifier: day12Identifier,
            dayOffset: 12,
            title: "ADBLX Premium Trial",
            body: "Your free trial ends in 3 days."
        ),
        Milestone(
            identifier: day14Identifier,
            dayOffset: 14,
            title: "ADBLX Premium Trial",
            body: "1 day left in your free trial."
        ),
        Milestone(
            identifier: day15Identifier,
            dayOffset: 15,
            title: "ADBLX Premium Trial",
            body: "Your 15-day free trial ends today."
        )
    ]

    private let notificationCenter: NotificationCenterProtocol
    private let entitlementService: EntitlementService
    private var observationTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "TrialNotificationScheduler")
    private static let signposter = OSSignposter(subsystem: "com.ADBLX.ADBLX", category: "TrialNotificationScheduler")

    public init(
        notificationCenter: NotificationCenterProtocol = RealNotificationCenter(),
        entitlementService: EntitlementService
    ) {
        self.notificationCenter = notificationCenter
        self.entitlementService = entitlementService
    }

    deinit {
        observationTask?.cancel()
    }

    public func startObserving() {
        guard observationTask == nil else { return }
        observationTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            for await state in await self.entitlementService.stateUpdates() {
                await self.handleEntitlementState(state)
            }
        }
    }

    private func handleEntitlementState(_ state: EntitlementState) async {
        switch state {
        case .trial:
            // Active trial: notifications remain scheduled
            break
        case .free, .monthly, .annual, .lifetime:
            // Purchase, cancellation, or trial expiration: cancel all pending trial notifications
            await cancelPendingTrialNotifications()
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func scheduleTrialNotifications(activatedAt: Date, referenceDate: Date = Date()) async throws {
        let spID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("trial.notificationsScheduled", id: spID)
        defer { Self.signposter.endInterval("trial.notificationsScheduled", interval) }

        // Remove any existing pending requests to ensure idempotency and prevent duplicates
        notificationCenter.removePendingNotificationRequests(withIdentifiers: Self.allTrialIdentifiers)

        let calendar = Calendar.current
        var scheduledCount = 0

        for milestone in Self.milestones {
            let triggerDate = activatedAt.addingTimeInterval(Double(milestone.dayOffset) * 86400)
            guard triggerDate > referenceDate else {
                continue
            }

            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: triggerDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

            let content = UNMutableNotificationContent()
            content.title = milestone.title
            content.body = milestone.body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: milestone.identifier,
                content: content,
                trigger: trigger
            )

            try await notificationCenter.add(request)
            scheduledCount += 1
        }

        Self.logger.info("Scheduled \(scheduledCount) trial notification(s) anchored to \(activatedAt)")
    }

    public func cancelPendingTrialNotifications() async {
        let spID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("trial.notificationsCancelled", id: spID)
        defer { Self.signposter.endInterval("trial.notificationsCancelled", interval) }

        notificationCenter.removePendingNotificationRequests(withIdentifiers: Self.allTrialIdentifiers)
        Self.logger.info("Cancelled all pending trial notifications")
    }
}
