// ADBLX/Features/Premium/Trial/TrialExpiryRouter.swift
import Foundation
import Observation
import UIKit
import os

public enum TrialExpiryRoute: Sendable, Equatable {
    case none
    case showExpiredDecision
}

@Observable
@MainActor
public final class TrialExpiryRouter {
    private let entitlementService: EntitlementService
    private let trialManager: TrialManagerProtocol
    private let decisionStore: TrialDecisionStoreProtocol

    public var currentRoute: TrialExpiryRoute = .none

    private nonisolated(unsafe) var entitlementTask: Task<Void, Never>?
    private nonisolated(unsafe) var foregroundObserver: NSObjectProtocol?
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "TrialExpiryRouter")

    public init(
        entitlementService: EntitlementService,
        trialManager: TrialManagerProtocol,
        decisionStore: TrialDecisionStoreProtocol
    ) {
        self.entitlementService = entitlementService
        self.trialManager = trialManager
        self.decisionStore = decisionStore

        setupObservers()
    }

    deinit {
        entitlementTask?.cancel()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    private func setupObservers() {
        entitlementTask = Task { [weak self] in
            guard let self else { return }
            for await _ in await self.entitlementService.stateUpdates() {
                await self.evaluateRoute()
            }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.evaluateRoute()
            }
        }
    }

    public func evaluateRoute() async {
        let isEntitled = await entitlementService.isPremiumEntitled()
        if isEntitled {
            if currentRoute != .none {
                Self.logger.info("Entitled to premium — setting route to .none")
                currentRoute = .none
            }
            return
        }

        let trialStatus = await trialManager.status()
        guard trialStatus == .expired else {
            if currentRoute != .none {
                Self.logger.info("Trial status \(String(describing: trialStatus)) — setting route to .none")
                currentRoute = .none
            }
            return
        }

        let hasChosenFree = await decisionStore.hasChosenFreeTier()
        if hasChosenFree {
            if currentRoute != .none {
                Self.logger.info("User previously chose free tier — setting route to .none")
                currentRoute = .none
            }
        } else {
            if currentRoute != .showExpiredDecision {
                Self.logger.info("Trial expired and free tier not chosen — routing to .showExpiredDecision")
                currentRoute = .showExpiredDecision
            }
        }
    }
}
