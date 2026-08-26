// ADBLX/Features/Onboarding/OnboardingCompletionStore.swift
import Foundation

public struct OnboardingCompletionStore: Sendable {
    private let defaults: UserDefaults
    private static let key = "hasCompletedOnboarding"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
