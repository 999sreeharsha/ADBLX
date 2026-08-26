// ADBLX/Features/Premium/Trial/TrialExpiredDecisionViewModel.swift
import Foundation
import Observation
import os

@Observable
@MainActor
public final class TrialExpiredDecisionViewModel {
    private let decisionStore: TrialDecisionStoreProtocol
    private let notificationScheduler: TrialNotificationSchedulerProtocol
    private let entitlementService: EntitlementService
    private let onDismiss: () -> Void

    public var showPaywallSheet: Bool = false
    public var isProcessing: Bool = false

    private nonisolated(unsafe) var entitlementTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "TrialExpiredDecisionViewModel")

    public init(
        decisionStore: TrialDecisionStoreProtocol,
        notificationScheduler: TrialNotificationSchedulerProtocol,
        entitlementService: EntitlementService,
        onDismiss: @escaping () -> Void
    ) {
        self.decisionStore = decisionStore
        self.notificationScheduler = notificationScheduler
        self.entitlementService = entitlementService
        self.onDismiss = onDismiss

        setupEntitlementObserver()
    }

    deinit {
        entitlementTask?.cancel()
    }

    private func setupEntitlementObserver() {
        entitlementTask = Task { [weak self] in
            guard let self else { return }
            for await state in await self.entitlementService.stateUpdates() {
                switch state {
                case .monthly, .annual, .lifetime:
                    Self.logger.info("Paid purchase detected (\(String(describing: state))) — dismissing decision view")
                    self.showPaywallSheet = false
                    self.onDismiss()
                case .trial, .free:
                    break
                }
            }
        }
    }

    public func continueWithFree() async {
        isProcessing = true
        defer { isProcessing = false }

        do {
            try await decisionStore.setChosenFreeTier(true)
            Self.logger.info("User confirmed Free Tier — persisted decision")
        } catch {
            Self.logger.error("Failed to persist free tier decision: \(error.localizedDescription)")
        }

        await notificationScheduler.cancelPendingTrialNotifications()
        onDismiss()
    }

    public func viewPremiumPlans() {
        showPaywallSheet = true
    }
}
