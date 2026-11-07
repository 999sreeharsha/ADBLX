import Testing
import UIKit
@testable import ADBLX

/// Settings rows whose feature doesn't exist yet stay out of Release builds
/// (`docs/gotchas.md`, "Settings screen (Sprint 5B)"), and nothing offers iCloud sync.
@Suite("Settings rows in Release")
struct SettingsReleaseRowsTests {
    @Test("With the flag off, Notifications, Safari Help and iCloud Sync are hidden")
    func placeholdersHiddenWithTheFlagOff() {
        #expect(SettingsPlaceholderRow.visible(placeholdersEnabled: false).isEmpty)
        #expect(SettingsPlaceholderRow.visible(placeholdersEnabled: true) == [.iCloudSync, .notifications, .safariHelp])
    }

    @Test("The build's own flag decides the default")
    func defaultFollowsTheBuild() {
        #if SETTINGS_PLACEHOLDERS_ENABLED
        #expect(BuildFeatures.settingsPlaceholders)
        #else
        #expect(!BuildFeatures.settingsPlaceholders)
        #endif
        #expect(SettingsPlaceholderRow.visible().isEmpty == !BuildFeatures.settingsPlaceholders)
    }

    @Test("Language opens the app's own page in iOS Settings")
    func languageOpensTheAppsSettingsPage() {
        #expect(SettingsView.languageSettingsURL == URL(string: UIApplication.openSettingsURLString))
    }

    @Test("The Home plan card never offers iCloud sync")
    func planCardHasNoICloudSync() {
        #expect(!ProtectionBreakdown.Item.allCases.map(\.titleKey).contains("home.plan.item.iCloudSync"))
    }
}
