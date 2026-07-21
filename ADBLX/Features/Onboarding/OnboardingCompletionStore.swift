// ADBLX/Features/Onboarding/OnboardingCompletionStore.swift
import Foundation

struct OnboardingCompletionStore {
    private let defaults: UserDefaults
    private static let key = "hasCompletedOnboarding"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
