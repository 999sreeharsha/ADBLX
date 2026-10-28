// ADBLX/Features/Settings/AppearancePreference.swift
import SwiftUI

/// Device-local UI preference, persisted with `@AppStorage(AppearancePreference.storageKey)`
/// (UserDefaults) rather than FilterStore/App Group metadata — this is app-chrome state,
/// not filtering data. The app root and the Settings picker both read the same key, so
/// there is no separate store to keep in sync.
enum AppearancePreference: String, CaseIterable, Codable {
    case system
    case light
    case dark

    static let storageKey = "appearancePreference"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var displayNameKey: LocalizedStringKey {
        switch self {
        case .system: return "settings.appearance.system"
        case .light: return "settings.appearance.light"
        case .dark: return "settings.appearance.dark"
        }
    }
}
