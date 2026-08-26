// ADBLXTests/Features/Premium/Trial/TrialKeychainStoreTests.swift
import Foundation
import Testing
@testable import ADBLX

@Suite("TrialKeychainStore", .serialized)
struct TrialKeychainStoreTests {
    @Test("Save, load, update, and delete round-trip in Keychain")
    func keychainRoundTrip() throws {
        let uniqueService = "com.ADBLX.test.trial.\(UUID().uuidString)"
        let store = TrialKeychainStore(service: uniqueService, account: "test_trial")
        
        defer { store.deleteRecord() }

        // Initial load is nil
        #expect(store.loadRecord() == nil)

        // Save new record
        let start = Date()
        let record = TrialRecord(
            activatedAt: start,
            duration: 15 * 86400,
            lastObservedDate: start,
            isExpired: false
        )
        try store.saveRecord(record)

        let loaded = store.loadRecord()
        #expect(loaded != nil)
        #expect(abs(loaded!.activatedAt.timeIntervalSince(start)) < 1.0)
        #expect(loaded!.isExpired == false)

        // Update record
        var updated = loaded!
        updated.isExpired = true
        try store.saveRecord(updated)

        let loadedUpdated = store.loadRecord()
        #expect(loadedUpdated?.isExpired == true)

        // Delete
        store.deleteRecord()
        #expect(store.loadRecord() == nil)
    }
}
