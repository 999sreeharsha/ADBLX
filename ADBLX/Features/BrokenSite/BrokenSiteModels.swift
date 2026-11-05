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

/// What a broken site report holds, shown to the user in full before anything is sent.
/// Only the registrable domain, issue, app version and enabled groups: no path, query, cookie
/// or identifier.
public struct BrokenSiteReport: Sendable, Equatable {
    /// Where reports go. `nil` leaves the mail's To field for the user to fill in.
    static let recipient: String? = nil

    public let domain: String
    public let category: BreakageCategory
    public let appVersion: String
    public let enabledGroups: [String]

    public init(domain: String, category: BreakageCategory, appVersion: String, enabledGroups: [String]) {
        self.domain = domain
        self.category = category
        self.appVersion = appVersion
        self.enabledGroups = enabledGroups
    }

    /// In English whatever the app's language, because it's read by the maintainers.
    public var bodyText: String {
        """
        ADBLX broken site report
        Site: \(domain)
        Issue: \(category.displayName)
        App version: \(appVersion)
        Enabled filter groups: \(enabledGroups.joined(separator: ", "))
        """
    }

    /// A `mailto:` URL rather than `MFMailComposeViewController`, whose `canSendMail()` is false
    /// unless Apple Mail is set up.
    public func mailURL(recipient: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient ?? ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Broken site: \(domain)"),
            URLQueryItem(name: "body", value: bodyText)
        ]
        return components.url
    }
}

/// How a report left the app.
public enum BrokenSiteDelivery: Sendable, Equatable {
    case mailOpened
    case copiedToClipboard
}
