// ADBLXTests/Features/Premium/Trial/TrialDecisionStoreTests.swift
import Foundation
import Testing
@testable import ADBLX

@Suite("TrialDecisionStore")
struct TrialDecisionStoreTests {
    @Test("InMemoryTrialDecisionStore defaults to false and updates value")
    func inMemoryStoreOperations() async throws {
        let store = InMemoryTrialDecisionStore()
        #expect(await store.hasChosenFreeTier() == false)

        try await store.setChosenFreeTier(true)
        #expect(await store.hasChosenFreeTier() == true)

        try await store.setChosenFreeTier(false)
        #expect(await store.hasChosenFreeTier() == false)
    }

    @Test("TrialKeychainDecisionStore writes and reads value from Keychain")
    func keychainStoreOperations() async throws {
        let uniqueAccount = "testUserChoseFreeTier-\(UUID().uuidString)"
        let store = TrialKeychainDecisionStore(service: "com.ADBLX.ADBLX.test", account: uniqueAccount)

        #expect(await store.hasChosenFreeTier() == false)

        try await store.setChosenFreeTier(true)
        #expect(await store.hasChosenFreeTier() == true)

        let reloadedStore = TrialKeychainDecisionStore(service: "com.ADBLX.ADBLX.test", account: uniqueAccount)
        #expect(await reloadedStore.hasChosenFreeTier() == true)
    }
}
