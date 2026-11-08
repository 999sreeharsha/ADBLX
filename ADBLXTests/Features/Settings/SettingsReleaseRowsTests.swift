import Testing
import UIKit
@testable import ADBLX

/// Settings rows whose feature doesn't exist yet stay out of Release builds
/// (`docs/gotchas.md`, "Settings screen (Sprint 5B)"), and nothing offers iCloud sync.
@Suite("Settings rows in Release")
struct SettingsReleaseRowsTests {
    @Test("With the flag off, Notifications, Safari Help, iCloud Sync and Language are hidden")
    func placeholdersHiddenWithTheFlagOff() {
        #expect(SettingsPlaceholderRow.visible(placeholdersEnabled: false, localizationCount: 1).isEmpty)
        #expect(SettingsPlaceholderRow.visible(placeholdersEnabled: true, localizationCount: 1)
            == [.iCloudSync, .notifications, .safariHelp, .language])
    }

    // With one localization, iOS's per-app language page offers nothing to choose.
    @Test("Language appears in any build once the app has a second localization")
    func languageNeedsASecondLocalization() {
        #expect(SettingsPlaceholderRow.visible(placeholdersEnabled: false, localizationCount: 2) == [.language])
    }

    @Test("The app ships one localization, so a Release build hides Language")
    func oneLocalizationToday() {
        #expect(SettingsPlaceholderRow.appLocalizationCount == 1, """
            A second localization was added: Release now shows the Language row. Check that iOS \
            offers the language on the app's Settings page, then delete this test.
            """)
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
