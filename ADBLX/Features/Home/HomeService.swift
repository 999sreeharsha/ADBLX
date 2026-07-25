// ADBLX/Features/Home/HomeService.swift
import Foundation

/// One activity-feed entry shown on Home (Stitch: "Recent Activity Feed").
struct HomeActivityEntry: Equatable, Identifiable {
    enum Kind {
        case trackerBlocked
        case filtersSynchronized
        case protectionToggled
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let timestamp: String

    static func == (lhs: HomeActivityEntry, rhs: HomeActivityEntry) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle && lhs.timestamp == rhs.timestamp
    }
}

/// Whether Safari content blocking is active. Only `.active` is implemented —
/// `.needsSetup`/`.unavailable` are reserved for a future sprint once Safari
/// extension-enablement detection exists (relates to onboarding FR-07, not
/// built yet). Do not add cases without a real detection mechanism behind them.
enum SafariProtectionStatus: Equatable {
    case active
}

/// Everything the Home screen needs to render (Stitch "Home Dashboard" screen).
///
/// Every field here must trace to real backend state — no fabricated or
/// heuristic values (Sprint 5A design doc). `blockedPercentage` and
/// `dnsProviderName` were removed for exactly this reason: Safari Content
/// Blockers give the app no block-event callback, and DNS status belongs to
/// the not-yet-built Packet Tunnel subsystem.
struct HomeStatus: Equatable {
    let isProtectionEnabled: Bool
    let safariProtectionStatus: SafariProtectionStatus
    let lastUpdateDescription: String
    let ruleCount: Int
    let recentActivity: [HomeActivityEntry]

    static let placeholder = HomeStatus(
        isProtectionEnabled: true,
        safariProtectionStatus: .active,
        lastUpdateDescription: "just now",
        ruleCount: 0,
        recentActivity: []
    )
}

/// What HomeView/HomeViewModel need from the backend. Never exposes
/// FilterPipeline or UpdateCoordinator directly (Sprint 4 spec §5) — a later
/// sprint's real implementation translates their state into a HomeStatus here.
protocol HomeService: Sendable {
    func fetchStatus() async -> HomeStatus
}

/// Sprint 4A/4B mock. Mirrors the Stitch "Home Dashboard" screen's sample
/// content exactly so the implemented screen visually matches the design.
struct MockHomeService: HomeService {
    func fetchStatus() async -> HomeStatus {
        HomeStatus(
            isProtectionEnabled: true,
            safariProtectionStatus: .active,
            lastUpdateDescription: "2m ago",
            ruleCount: 142_042,
            recentActivity: [
                HomeActivityEntry(
                    kind: .trackerBlocked,
                    title: "google-analytics.com",
                    subtitle: "Tracker blocked in Safari",
                    timestamp: "14:22"
                ),
                HomeActivityEntry(
                    kind: .filtersSynchronized,
                    title: "Filters Synchronized",
                    subtitle: "Successfully updated 4 filter lists",
                    timestamp: "12:05"
                ),
                HomeActivityEntry(
                    kind: .protectionToggled,
                    title: "Protection Enabled",
                    subtitle: "Global toggle switched to ON",
                    timestamp: "09:00"
                ),
            ]
        )
    }
}
