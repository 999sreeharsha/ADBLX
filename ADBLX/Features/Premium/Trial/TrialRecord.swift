// ADBLX/Features/Premium/Trial/TrialRecord.swift
import Foundation

public struct TrialRecord: Codable, Equatable, Sendable {
    public let activatedAt: Date
    public let duration: TimeInterval
    public var lastObservedDate: Date
    public var isExpired: Bool

    public var expiresAt: Date {
        activatedAt.addingTimeInterval(duration)
    }

    public init(
        activatedAt: Date,
        duration: TimeInterval = 15 * 86400,
        lastObservedDate: Date,
        isExpired: Bool = false
    ) {
        self.activatedAt = activatedAt
        self.duration = duration
        self.lastObservedDate = lastObservedDate
        self.isExpired = isExpired
    }
}

public enum TrialStatus: Equatable, Sendable {
    case notStarted
    case active(expiresAt: Date, daysRemaining: Int)
    case expired

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}
