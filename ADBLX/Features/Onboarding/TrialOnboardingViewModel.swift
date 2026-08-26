// ADBLX/Features/Onboarding/TrialOnboardingViewModel.swift
import Foundation
import Observation
import os

@Observable
@MainActor
public final class TrialOnboardingViewModel {
    private let trialManager: TrialManagerProtocol
    private let entitlementService: EntitlementService
    private let notificationScheduler: TrialNotificationSchedulerProtocol
    private var onboardingStore: OnboardingCompletionStore
    private let onFinish: () -> Void

    public var isActivating: Bool = false
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "TrialOnboardingViewModel")

    public init(
        trialManager: TrialManagerProtocol,
        entitlementService: EntitlementService,
        notificationScheduler: TrialNotificationSchedulerProtocol,
        onboardingStore: OnboardingCompletionStore = OnboardingCompletionStore(),
        onFinish: @escaping () -> Void
    ) {
        self.trialManager = trialManager
        self.entitlementService = entitlementService
        self.notificationScheduler = notificationScheduler
        self.onboardingStore = onboardingStore
        self.onFinish = onFinish
    }

    public func startFreeTrial() async {
        isActivating = true
        defer { isActivating = false }

        let activationDate = Date()
        let status = await trialManager.activateTrial(at: activationDate)
        Self.logger.info("Trial activation result: \(String(describing: status))")

        await entitlementService.refreshEntitlements()

        do {
            let granted = try await notificationScheduler.requestAuthorization()
            if granted {
                try await notificationScheduler.scheduleTrialNotifications(activatedAt: activationDate)
                Self.logger.info("Notification permission granted — 5 trial milestones scheduled")
            } else {
                Self.logger.info("Notification permission declined — proceeding with active trial")
            }
        } catch {
            Self.logger.error("Notification authorization error: \(error.localizedDescription) — proceeding")
        }

        onboardingStore.hasCompletedOnboarding = true
        onFinish()
    }

    public func continueWithFree() {
        Self.logger.info("User chose to continue with free tier during onboarding")
        onboardingStore.hasCompletedOnboarding = true
        onFinish()
    }
}
