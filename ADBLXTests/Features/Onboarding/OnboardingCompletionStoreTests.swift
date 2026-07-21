// ADBLXTests/Features/Onboarding/OnboardingCompletionStoreTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("OnboardingCompletionStore")
struct OnboardingCompletionStoreTests {
    @Test("defaults to false for a fresh UserDefaults suite")
    func defaultsToFalse() {
        let suiteName = "OnboardingCompletionStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OnboardingCompletionStore(defaults: defaults)

        #expect(store.hasCompletedOnboarding == false)
    }

    @Test("setting hasCompletedOnboarding persists across store instances")
    func persistsAcrossInstances() {
        let suiteName = "OnboardingCompletionStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var store = OnboardingCompletionStore(defaults: defaults)

        store.hasCompletedOnboarding = true

        let reloaded = OnboardingCompletionStore(defaults: defaults)
        #expect(reloaded.hasCompletedOnboarding == true)
    }
}
