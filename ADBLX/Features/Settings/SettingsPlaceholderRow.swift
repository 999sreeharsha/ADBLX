import Foundation

/// Settings rows whose feature doesn't exist yet: iCloud Sync (no sync backend), Notifications
/// and Safari Help (both "coming soon" screens). Shown only in builds with
/// `SETTINGS_PLACEHOLDERS_ENABLED` (Debug), never in Release (`docs/gotchas.md`, "Settings screen").
/// Language opens the app's page in iOS Settings, which offers a language only once the app has
/// a second localization; until then it's a placeholder too.
nonisolated enum SettingsPlaceholderRow: CaseIterable, Equatable {
    case iCloudSync
    case notifications
    case safariHelp
    case language

    static func visible(
        placeholdersEnabled: Bool = BuildFeatures.settingsPlaceholders,
        localizationCount: Int = appLocalizationCount
    ) -> [Self] {
        allCases.filter { row in
            placeholdersEnabled || (row == .language && localizationCount > 1)
        }
    }

    /// The languages the app is translated into (`Base` isn't one).
    static var appLocalizationCount: Int {
        Bundle.main.localizations.filter { $0 != "Base" }.count
    }
}
