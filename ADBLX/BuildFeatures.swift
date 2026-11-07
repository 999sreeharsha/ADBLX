import Foundation

/// Features a build includes, decided at compile time in `Config/*.xcconfig`. Deliberately not
/// a remote flag: hiding a feature from review and switching it on later is what App Store
/// Guideline 2.3.1 rejects.
nonisolated enum BuildFeatures {
    /// On in Debug, off in Release, until the connectivity bug in `docs/gotchas.md` is closed.
    static var dnsProtection: Bool {
        #if DNS_PROTECTION_ENABLED
        return true
        #else
        return false
        #endif
    }


    /// On in Debug, off in Release: Settings rows for features that don't exist yet
    /// (`SettingsPlaceholderRow`), so a Release build never shows a row that leads nowhere.
    static var settingsPlaceholders: Bool {
        #if SETTINGS_PLACEHOLDERS_ENABLED
        return true
        #else
        return false
        #endif
    }
}
