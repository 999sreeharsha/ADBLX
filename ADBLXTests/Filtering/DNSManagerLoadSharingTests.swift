import Foundation
import NetworkExtension
import os
import Testing
@testable import ADBLX

/// `getOrLoadManager` used to check the cached tunnel manager and then load one with the lock
/// released, so two callers at once (the status load and the entitlement-loss teardown at
/// launch, say) each loaded, and with no saved configuration each made a new
/// `NETunnelProviderManager`. Callers that arrive while a load is in progress now wait for it.
@Suite("DNS tunnel manager load sharing", .timeLimit(.minutes(1)))
struct DNSManagerLoadSharingTests {
    /// A load that finishes only when the test says so, counting how often it starts.
    nonisolated final class HeldManagerLoad: @unchecked Sendable {
        private let lock = NSLock()
        private var starts = 0
        private let gate = AsyncStream.makeStream(of: Void.self)

        var loadCount: Int { lock.withLock { starts } }

        func load() async throws -> NETunnelProviderManager {
            lock.withLock { starts += 1 }
            for await _ in gate.stream { break }
            return NETunnelProviderManager()
        }

        /// Lets every waiting and future load finish.
        func finish() { gate.continuation.finish() }
    }

    private func makeService(loadManager: @escaping @Sendable () async throws -> NETunnelProviderManager) -> RealDNSProtectionService {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let settings = DNSProtectionSettingsStore(userDefaults: UserDefaults(suiteName: "DNSManagerLoad_\(UUID().uuidString)")!)
        settings.setEnabled(false)
        return RealDNSProtectionService(
            settingsStore: settings,
            entitlementService: MockSubscriptionService(state: .annual(expiresAt: Date().addingTimeInterval(86400))),
            neverBlockStore: DNSNeverBlockStore(filterStore: FilterStore(overrideBaseURL: dir), seed: { [] }),
            loadManager: loadManager
        )
    }

    @Test("two simultaneous callers share one load and get the same manager")
    func simultaneousCallersShareOneLoad() async throws {
        let held = HeldManagerLoad()
        let service = makeService { try await held.load() }

        async let first = service.getOrLoadManager()
        async let second = service.getOrLoadManager()
        for _ in 0..<100_000 where service.managerLoadCallers < 2 { await Task.yield() }
        #expect(service.managerLoadCallers == 2)

        held.finish()
        let (a, b) = await (first, second)

        #expect(held.loadCount == 1)
        let managerA = try #require(a)
        let managerB = try #require(b)
        #expect(managerA === managerB)
    }

    @Test("a failed load isn't kept: the next caller loads again")
    func failedLoadIsRetried() async throws {
        let attempts = HeldManagerLoad()
        attempts.finish()
        let failFirst = OSAllocatedUnfairLock(initialState: true)
        let service = makeService {
            let shouldFail = failFirst.withLock { state in defer { state = false }; return state }
            if shouldFail { throw CocoaError(.fileReadUnknown) }
            return try await attempts.load()
        }

        #expect(await service.getOrLoadManager() == nil)
        #expect(await service.getOrLoadManager() != nil)
        #expect(attempts.loadCount == 1)
    }
}
