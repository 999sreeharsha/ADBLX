// ADBLXTests/Features/Onboarding/TrialOnboardingViewModelTests.swift
import Foundation
import Testing
@testable import ADBLX

final class MockTrialNotificationScheduler: TrialNotificationSchedulerProtocol, @unchecked Sendable {
    var authorizationResult: Bool = true
    var authorizationError: Error?
    var scheduledActivations: [Date] = []
    var cancelledCount: Int = 0

    func requestAuthorization() async throws -> Bool {
        if let error = authorizationError {
            throw error
        }
        return authorizationResult
    }

    func scheduleTrialNotifications(activatedAt: Date, referenceDate: Date) async throws {
        scheduledActivations.append(activatedAt)
    }

    func cancelPendingTrialNotifications() async {
        cancelledCount += 1
    }
}

@Suite("TrialOnboardingViewModel", .serialized)
@MainActor
struct TrialOnboardingViewModelTests {
    @Test("startFreeTrial activates trial, requests notifications, and completes onboarding")
    func startFreeTrialSuccess() async {
        let trialStore = InMemoryTrialStore()
        let trialManager = TrialManager(store: trialStore)
        let mockEntitlement = MockSubscriptionService(state: .free)
        let scheduler = MockTrialNotificationScheduler()
        let userDefaults = UserDefaults(suiteName: "TrialOnboardingTests-\(UUID().uuidString)")!
        let onboardingStore = OnboardingCompletionStore(defaults: userDefaults)
        var finished = false

        let viewModel = TrialOnboardingViewModel(
            trialManager: trialManager,
            entitlementService: mockEntitlement,
            notificationScheduler: scheduler,
            onboardingStore: onboardingStore,
            onFinish: { finished = true }
        )

        await viewModel.startFreeTrial()

        let status = await trialManager.status()
        #expect(status.isActive)
        #expect(scheduler.scheduledActivations.count == 1)
        #expect(onboardingStore.hasCompletedOnboarding == true)
        #expect(finished == true)
    }

    @Test("startFreeTrial when notification permission denied still activates trial and finishes")
    func startFreeTrialPermissionDenied() async {
        let trialStore = InMemoryTrialStore()
        let trialManager = TrialManager(store: trialStore)
        let mockEntitlement = MockSubscriptionService(state: .free)
        let scheduler = MockTrialNotificationScheduler()
        scheduler.authorizationResult = false
        let userDefaults = UserDefaults(suiteName: "TrialOnboardingTests-\(UUID().uuidString)")!
        let onboardingStore = OnboardingCompletionStore(defaults: userDefaults)
        var finished = false

        let viewModel = TrialOnboardingViewModel(
            trialManager: trialManager,
            entitlementService: mockEntitlement,
            notificationScheduler: scheduler,
            onboardingStore: onboardingStore,
            onFinish: { finished = true }
        )

        await viewModel.startFreeTrial()

        let status = await trialManager.status()
        #expect(status.isActive)
        #expect(scheduler.scheduledActivations.isEmpty)
        #expect(onboardingStore.hasCompletedOnboarding == true)
        #expect(finished == true)
    }

    @Test("startFreeTrial when notification authorization throws error still activates trial and finishes")
    func startFreeTrialPermissionThrows() async {
        struct DummyError: Error {}
        let trialStore = InMemoryTrialStore()
        let trialManager = TrialManager(store: trialStore)
        let mockEntitlement = MockSubscriptionService(state: .free)
        let scheduler = MockTrialNotificationScheduler()
        scheduler.authorizationError = DummyError()
        let userDefaults = UserDefaults(suiteName: "TrialOnboardingTests-\(UUID().uuidString)")!
        let onboardingStore = OnboardingCompletionStore(defaults: userDefaults)
        var finished = false

        let viewModel = TrialOnboardingViewModel(
            trialManager: trialManager,
            entitlementService: mockEntitlement,
            notificationScheduler: scheduler,
            onboardingStore: onboardingStore,
            onFinish: { finished = true }
        )

        await viewModel.startFreeTrial()

        let status = await trialManager.status()
        #expect(status.isActive)
        #expect(scheduler.scheduledActivations.isEmpty)
        #expect(onboardingStore.hasCompletedOnboarding == true)
        #expect(finished == true)
    }

    @Test("continueWithFree completes onboarding without activating trial")
    func continueWithFreeDoesNotActivate() async {
        let trialStore = InMemoryTrialStore()
        let trialManager = TrialManager(store: trialStore)
        let mockEntitlement = MockSubscriptionService(state: .free)
        let scheduler = MockTrialNotificationScheduler()
        let userDefaults = UserDefaults(suiteName: "TrialOnboardingTests-\(UUID().uuidString)")!
        let onboardingStore = OnboardingCompletionStore(defaults: userDefaults)
        var finished = false

        let viewModel = TrialOnboardingViewModel(
            trialManager: trialManager,
            entitlementService: mockEntitlement,
            notificationScheduler: scheduler,
            onboardingStore: onboardingStore,
            onFinish: { finished = true }
        )

        viewModel.continueWithFree()

        let status = await trialManager.status()
        #expect(status == .notStarted)
        #expect(scheduler.scheduledActivations.isEmpty)
        #expect(onboardingStore.hasCompletedOnboarding == true)
        #expect(finished == true)
    }
}
