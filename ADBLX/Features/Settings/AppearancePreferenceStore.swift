// ADBLX/Features/Settings/AppearancePreferenceStore.swift
import SwiftUI

/// Device-local UI preference, deliberately backed by UserDefaults rather than
/// FilterStore/App Group metadata — this is app-chrome state, not filtering data,
/// so it doesn't belong alongside installed_filters.json/filter_preferences.json
/// (Sprint 5B design doc).
enum AppearancePreference: String, CaseIterable, Codable {
    case system
    case light
    case dark

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

struct AppearancePreferenceStore {
    private static let key = "appearancePreference"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var current: AppearancePreference {
        get {
            guard let rawValue = defaults.string(forKey: Self.key),
                  let preference = AppearancePreference(rawValue: rawValue) else {
                return .system
            }
            return preference
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}
