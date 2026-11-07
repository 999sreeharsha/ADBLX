/// Settings rows whose feature doesn't exist yet: iCloud Sync (no sync backend), Notifications
/// and Safari Help (both "coming soon" screens). Shown only in builds with
/// `SETTINGS_PLACEHOLDERS_ENABLED` (Debug), never in Release (`docs/gotchas.md`, "Settings screen").
nonisolated enum SettingsPlaceholderRow: CaseIterable, Equatable {
    case iCloudSync
    case notifications
    case safariHelp

    static func visible(placeholdersEnabled: Bool = BuildFeatures.settingsPlaceholders) -> [Self] {
        placeholdersEnabled ? allCases : []
    }
}
