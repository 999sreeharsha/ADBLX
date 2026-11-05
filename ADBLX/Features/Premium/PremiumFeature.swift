import SwiftUI

/// A Premium feature the paywall can open focused on, so a tap on a locked control explains
/// that control rather than showing a generic upsell.
nonisolated enum PremiumFeature: CaseIterable, Equatable, Sendable {
    case dnsProtection
    case premiumFilterLists
    case backgroundUpdates
    case youtube

    /// Default order, with `focus` (if any) moved to the front.
    static func displayOrder(focus: PremiumFeature?, dnsEnabled: Bool = BuildFeatures.dnsProtection) -> [PremiumFeature] {
        let features = allCases.filter { dnsEnabled || $0 != .dnsProtection }
        guard let focus, features.contains(focus) else { return features }
        return [focus] + features.filter { $0 != focus }
    }

    /// The feature a tap on `list` should open the paywall for, or nil when the list is usable.
    static func lockedFeature(for list: FilterListEntry, isEntitled: Bool) -> PremiumFeature? {
        list.isPremium && !isEntitled ? .premiumFilterLists : nil
    }

    var icon: String {
        switch self {
        case .dnsProtection: return "network"
        case .premiumFilterLists: return "rectangle.badge.xmark"
        case .backgroundUpdates: return "arrow.triangle.2.circlepath"
        case .youtube: return "play.tv.fill"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .dnsProtection: return "premium.feature.dns.title"
        case .premiumFilterLists: return "premium.feature.filterLists.title"
        case .backgroundUpdates: return "premium.feature.backgroundUpdates.title"
        case .youtube: return "premium.feature.youtube.title"
        }
    }

    var descriptionKey: LocalizedStringKey {
        switch self {
        case .dnsProtection: return "premium.feature.dns.description"
        case .premiumFilterLists: return "premium.feature.filterLists.description"
        case .backgroundUpdates: return "premium.feature.backgroundUpdates.description"
        case .youtube: return "premium.feature.youtube.description"
        }
    }
}

/// A row of the paywall's Free/Premium comparison.
nonisolated enum PremiumComparisonRow: CaseIterable, Equatable, Sendable {
    case safariBlocking
    case dnsProtection
    case autoUpdates
    case premiumThemes

    static func visible(dnsEnabled: Bool = BuildFeatures.dnsProtection) -> [PremiumComparisonRow] {
        allCases.filter { dnsEnabled || $0 != .dnsProtection }
    }

    var featureKey: LocalizedStringKey {
        switch self {
        case .safariBlocking: return "premium.comparison.safariBlocking"
        case .dnsProtection: return "premium.comparison.dnsProtection"
        case .autoUpdates: return "premium.comparison.autoUpdates"
        case .premiumThemes: return "premium.comparison.premiumThemes"
        }
    }

    var freeIncluded: Bool { self == .safariBlocking }
}
