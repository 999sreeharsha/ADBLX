// ADBLXTests/Features/Settings/AppearancePreferenceTests.swift
import Testing
import Foundation
import SwiftUI
@testable import ADBLX

@Suite("AppearancePreference")
struct AppearancePreferenceTests {
    @Test("colorScheme maps .system to nil, .light to .light, .dark to .dark")
    func colorSchemeMapping() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }

    @Test("raw values are the persisted strings and decode back")
    func rawValuesRoundTrip() {
        #expect(AppearancePreference.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(AppearancePreference(rawValue: "dark") == .dark)
        #expect(AppearancePreference(rawValue: "bogus") == nil)
    }
}
