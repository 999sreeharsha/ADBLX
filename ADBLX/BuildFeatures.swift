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


    /// On in Debug, off in Release: background filter updates. With it off the app declares no
    /// background modes or task identifiers (project.yml, ADR-0014), so nothing may register a
    /// background task. `BACKGROUND_UPDATES_ENABLED` in `Config/Debug.xcconfig`.
    static var backgroundUpdates: Bool {
        #if BACKGROUND_UPDATES_ENABLED
        return true
        #else
        return false
        #endif
    }

    /// On in Debug, off in Release: Premium allowlist sync through iCloud key-value storage.
    /// Release is signed without the iCloud entitlement, and the privacy policy doesn't mention
    /// iCloud. `ICLOUD_SYNC_ENABLED` in `Config/Debug.xcconfig`.
    static var iCloudSync: Bool {
        #if ICLOUD_SYNC_ENABLED
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
