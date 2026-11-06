// ADBLXTests/Filtering/Deployment/ContentBlockerStateProvidingTests.swift
import Testing
import Foundation
@testable import ADBLX

// The conformance is in an extension on purpose. Declared here, it makes the compiler infer
// `nonisolated` for the actor in some build batches, and then reject it (docs/gotchas.md).
actor MockContentBlockerStateProvider {
    var states: [String: ContentBlockerSettingsState] = [:]

    init(states: [String: ContentBlockerSettingsState] = [:]) {
        self.states = states
    }

    func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState {
        states[extensionIdentifier] ?? .enabled
    }

    func setState(_ state: ContentBlockerSettingsState, for extensionIdentifier: String) {
        states[extensionIdentifier] = state
    }
}

extension MockContentBlockerStateProvider: ContentBlockerStateProviding {}

@Suite("ContentBlockerStateProviding")
struct ContentBlockerStateProvidingTests {
    @Test("MockContentBlockerStateProvider returns configured states")
    func returnsConfiguredStates() async {
        let provider = MockContentBlockerStateProvider(states: [
            "com.ADBLX.ADBLX.AdsBlocker": .enabled,
            "com.ADBLX.ADBLX.PrivacyBlocker": .disabled,
            "com.ADBLX.ADBLX.AnnoyancesBlocker": .unavailable("Extension not found")
        ])

        let adsState = await provider.state(of: "com.ADBLX.ADBLX.AdsBlocker")
        let privacyState = await provider.state(of: "com.ADBLX.ADBLX.PrivacyBlocker")
        let annoyancesState = await provider.state(of: "com.ADBLX.ADBLX.AnnoyancesBlocker")
        let unconfiguredState = await provider.state(of: "com.unknown")

        #expect(adsState == .enabled)
        #expect(privacyState == .disabled)
        #expect(annoyancesState == .unavailable("Extension not found"))
        #expect(unconfiguredState == .enabled)
    }
}
