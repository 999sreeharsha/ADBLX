// ADBLXTests/Filtering/Updates/UpdateThrottleTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("UpdateThrottle", .serialized)
struct UpdateThrottleTests {
    @Test("shouldRun is true when no timestamp has ever been recorded")
    func shouldRunTrueWithNoPriorRecord() async throws {
        let store = FilterStore.temporary()
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("update_throttle.json"))

        let throttle = UpdateThrottle(store: store, interval: 3600)
        #expect(await throttle.shouldRun(now: Date()) == true)
    }

    @Test("shouldRun is false immediately after recordSuccess, within the interval")
    func shouldRunFalseWithinInterval() async throws {
        let store = FilterStore.temporary()
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("update_throttle.json"))

        let throttle = UpdateThrottle(store: store, interval: 3600)
        let now = Date()
        try await throttle.recordSuccess(at: now)

        #expect(await throttle.shouldRun(now: now.addingTimeInterval(60)) == false)

        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("update_throttle.json"))
    }

    @Test("shouldRun is true again once the interval has elapsed")
    func shouldRunTrueAfterIntervalElapses() async throws {
        let store = FilterStore.temporary()
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("update_throttle.json"))

        let throttle = UpdateThrottle(store: store, interval: 3600)
        let now = Date()
        try await throttle.recordSuccess(at: now)

        #expect(await throttle.shouldRun(now: now.addingTimeInterval(3601)) == true)

        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("update_throttle.json"))
    }
}
