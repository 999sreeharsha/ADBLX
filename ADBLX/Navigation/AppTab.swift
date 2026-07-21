// ADBLX/Navigation/AppTab.swift
import Foundation

/// The four frozen top-level destinations (Sprint 4 spec §3). Adding a fifth tab
/// requires a product decision, not just a code change — see the spec's
/// "explicitly excluded" list before adding anything here.
enum AppTab: CaseIterable {
    case home
    case protection
    case premium
    case settings

    var title: String {
        switch self {
        case .home: return "Home"
        case .protection: return "Protection"
        case .premium: return "Premium"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .protection: return "shield.fill"
        case .premium: return "star.fill"
        case .settings: return "gearshape.fill"
        }
    }
}
