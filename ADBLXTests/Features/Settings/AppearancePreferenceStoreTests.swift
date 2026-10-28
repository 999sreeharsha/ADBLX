// ADBLXTests/Features/Settings/AppearancePreferenceStoreTests.swift
import Testing
import Foundation
import SwiftUI
@testable import ADBLX

@Suite("AppearancePreferenceStore")
struct AppearancePreferenceStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppearancePreferenceStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("defaults to .system when nothing has been set")
    func defaultsToSystem() {
        let store = AppearancePreferenceStore(defaults: makeDefaults())

        #expect(store.current == .system)
    }

    @Test("setting current persists across a fresh store instance backed by the same UserDefaults")
    func settingPersists() {
        let defaults = makeDefaults()
        var store = AppearancePreferenceStore(defaults: defaults)

        store.current = .dark

        let freshInstance = AppearancePreferenceStore(defaults: defaults)
        #expect(freshInstance.current == .dark)
    }

    @Test("colorScheme maps .system to nil, .light to .light, .dark to .dark")
    func colorSchemeMapping() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }
}
