// ADBLX/Features/Premium/Trial/TrialManager.swift
import Foundation
import os

public protocol TrialManagerProtocol: Sendable {
    func status(at date: Date) async -> TrialStatus
    func activateTrial(at date: Date) async -> TrialStatus
    func currentEntitlement(at date: Date) async -> EntitlementState
}

public extension TrialManagerProtocol {
    func status() async -> TrialStatus {
        await status(at: Date())
    }

    func activateTrial() async -> TrialStatus {
        await activateTrial(at: Date())
    }

    func currentEntitlement() async -> EntitlementState {
        await currentEntitlement(at: Date())
    }
}

public actor TrialManager: TrialManagerProtocol {
    private let store: TrialStoreProtocol
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "TrialManager")
    private static let signposter = OSSignposter(subsystem: "com.ADBLX.ADBLX", category: "TrialManager")

    public init(store: TrialStoreProtocol = TrialKeychainStore()) {
        self.store = store
    }

    public func activateTrial(at date: Date = Date()) async -> TrialStatus {
        let spID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("trial.statusEvaluation", id: spID)
        defer { Self.signposter.endInterval("trial.statusEvaluation", interval) }

        if let existing = store.loadRecord() {
            return evaluateStatus(for: existing, at: date)
        }

        let newRecord = TrialRecord(
            activatedAt: date,
            duration: 15 * 86400,
            lastObservedDate: date,
            isExpired: false
        )
        do {
            try store.saveRecord(newRecord)
            Self.logger.info("Universal 15-day trial activated at \(date)")
            return .active(expiresAt: newRecord.expiresAt, daysRemaining: 15)
        } catch {
            Self.logger.error("Failed to save TrialRecord: \(error.localizedDescription)")
            return .notStarted
        }
    }

    public func status(at date: Date = Date()) async -> TrialStatus {
        let spID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("trial.statusEvaluation", id: spID)
        defer { Self.signposter.endInterval("trial.statusEvaluation", interval) }

        guard let record = store.loadRecord() else {
            return .notStarted
        }
        return evaluateStatus(for: record, at: date)
    }

    public func currentEntitlement(at date: Date = Date()) async -> EntitlementState {
        let currentStatus = await status(at: date)
        switch currentStatus {
        case .active(let expiresAt, _):
            return .trial(expiresAt: expiresAt)
        case .notStarted, .expired:
            return .free
        }
    }

    private func evaluateStatus(for record: TrialRecord, at date: Date) -> TrialStatus {
        if record.isExpired {
            return .expired
        }

        var mutableRecord = record
        let effectiveDate = max(date, mutableRecord.lastObservedDate)

        if effectiveDate >= mutableRecord.expiresAt {
            let expID = Self.signposter.makeSignpostID()
            Self.signposter.emitEvent(
                "trial.expiryTransition",
                id: expID,
                "Trial transitioned to expired"
            )
            Self.logger.info("Trial expired at effectiveDate \(effectiveDate)")
            mutableRecord.isExpired = true
            try? store.saveRecord(mutableRecord)
            return .expired
        }

        if date > mutableRecord.lastObservedDate {
            mutableRecord.lastObservedDate = date
            try? store.saveRecord(mutableRecord)
        }

        let secondsRemaining = mutableRecord.expiresAt.timeIntervalSince(effectiveDate)
        let daysRemaining = max(1, Int(ceil(secondsRemaining / 86400)))
        return .active(expiresAt: mutableRecord.expiresAt, daysRemaining: daysRemaining)
    }
}
