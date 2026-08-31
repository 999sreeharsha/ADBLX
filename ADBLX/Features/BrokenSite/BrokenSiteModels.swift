// ADBLX/Features/BrokenSite/BrokenSiteModels.swift
import Foundation

/// Categorization of website breakage or filtering failure.
public enum BreakageCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case adsNotBlocked = "ads_not_blocked"
    case pageLayoutBroken = "page_layout_broken"
    case mediaPlaybackFailed = "media_playback_failed"
    case loginOrFormBroken = "login_or_form_broken"
    case antiAdblockDetected = "anti_adblock_detected"
    case other = "other"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .adsNotBlocked:
            return "Ads Still Showing"
        case .pageLayoutBroken:
            return "Page Layout Broken"
        case .mediaPlaybackFailed:
            return "Video / Audio Playback Broken"
        case .loginOrFormBroken:
            return "Login / Forms Not Working"
        case .antiAdblockDetected:
            return "Ad Blocker Warning / Block"
        case .other:
            return "Other Issue"
        }
    }

    public var iconName: String {
        switch self {
        case .adsNotBlocked:
            return "eye.slash"
        case .pageLayoutBroken:
            return "rectangle.split.3x3"
        case .mediaPlaybackFailed:
            return "play.slash"
        case .loginOrFormBroken:
            return "person.crop.circle.badge.exclamationmark"
        case .antiAdblockDetected:
            return "shield.slash"
        case .other:
            return "questionmark.circle"
        }
    }
}

/// Privacy-preserving reporting payload schema.
/// Strictly contains domain, filter versions, and diagnostic category; ZERO user PII, cookies, or URL paths.
public struct BrokenSiteReportPayload: Codable, Sendable, Equatable {
    public let reportID: String
    public let domain: String
    public let breakageCategory: BreakageCategory
    public let notes: String?
    public let timestamp: Date
    public let appVersion: String
    public let iosVersion: String
    public let activeFilterVersions: [String: String]
    public let dnsProtectionEnabled: Bool
    public let upstreamResolver: String?

    public init(
        reportID: String = UUID().uuidString,
        domain: String,
        breakageCategory: BreakageCategory,
        notes: String? = nil,
        timestamp: Date = Date(),
        appVersion: String = "1.0",
        iosVersion: String = "26.5",
        activeFilterVersions: [String: String] = [:],
        dnsProtectionEnabled: Bool = false,
        upstreamResolver: String? = nil
    ) {
        self.reportID = reportID
        self.domain = domain
        self.breakageCategory = breakageCategory
        self.notes = notes
        self.timestamp = timestamp
        self.appVersion = appVersion
        self.iosVersion = iosVersion
        self.activeFilterVersions = activeFilterVersions
        self.dnsProtectionEnabled = dnsProtectionEnabled
        self.upstreamResolver = upstreamResolver
    }
}

/// Result of broken site reporting and recovery flow.
public enum ReportSubmissionResult: Sendable, Equatable {
    case success(reportID: String, domain: String, allowlisted: Bool)
    case allowlistedOnly(domain: String, networkError: String)
    case failed(reason: String)
}
