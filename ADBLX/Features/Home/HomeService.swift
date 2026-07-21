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

/// Everything the Home screen needs to render (Stitch "Home Dashboard" screen).
struct HomeStatus: Equatable {
    let isProtectionEnabled: Bool
    let dnsProviderName: String
    let lastUpdateDescription: String
    let ruleCount: Int
    let blockedPercentage: Double
    let recentActivity: [HomeActivityEntry]

    static let placeholder = HomeStatus(
        isProtectionEnabled: true,
        dnsProviderName: "NextDNS",
        lastUpdateDescription: "just now",
        ruleCount: 0,
        blockedPercentage: 0,
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
            dnsProviderName: "NextDNS",
            lastUpdateDescription: "2m ago",
            ruleCount: 142_042,
            blockedPercentage: 99.2,
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
