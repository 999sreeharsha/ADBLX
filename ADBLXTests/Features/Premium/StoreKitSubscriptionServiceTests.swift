// ADBLXTests/Features/Premium/StoreKitSubscriptionServiceTests.swift
import Testing
import StoreKit
import Foundation
@testable import ADBLX

@Suite("StoreKitSubscriptionService")
struct StoreKitSubscriptionServiceTests {
    @Test("currentState is .free with no transactions")
    func initialStateIsFreeWithNoTransactions() async throws {
        let service = StoreKitSubscriptionService()
        let state = await service.currentState
        #expect(state == .free)
        let entitled = await service.isPremiumEntitled()
        #expect(entitled == false)
    }

    @Test("stateUpdates() yields current state immediately to new subscribers")
    func stateUpdatesYieldsCurrentStateImmediately() async throws {
        let service = StoreKitSubscriptionService()
        var iterator = await service.stateUpdates().makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial == .free)
    }

    @Test("Multiple subscribers receive initial state independently")
    func multipleSubscribersReceiveInitialState() async throws {
        let service = StoreKitSubscriptionService()
        var iter1 = await service.stateUpdates().makeAsyncIterator()
        var iter2 = await service.stateUpdates().makeAsyncIterator()
        
        let initial1 = await iter1.next()
        let initial2 = await iter2.next()
        #expect(initial1 == .free)
        #expect(initial2 == .free)
    }

    @Test(
        "fetchStatus returns three plans: monthly, annual, lifetime",
        .disabled("Skipped: StoreKit Local Configuration does not activate correctly under headless xcodebuild test on the current Xcode toolchain. Verified manually in Xcode GUI.")
    )
    func fetchStatusReturnsThreePlans() async throws {
        let service = StoreKitSubscriptionService()
        let status = await service.fetchStatus()
        #expect(status.plans.map(\.id).sorted() == ["annual", "lifetime", "monthly"])
    }

    /// Regression: the Layer 3 (Safari Web Extension) bootstrap in `ADBLXApp` publishes
    /// `entitlement.json` at launch from the service's entitlement answer. Reading the
    /// lazily-populated `state` snapshot there (still `.free` until the async transaction
    /// listener resolves) gave a user with an ACTIVE TRIAL `entitlement.json = {free}`,
    /// so background.js failed closed and Layer 3 stayed off until a second launch.
    @Test("resolvedPremiumEntitlement() reflects an active trial with no prior refresh call")
    func resolvedPremiumEntitlementResolvesTrialOnDemand() async throws {
        let expiry = Date().addingTimeInterval(60 * 60 * 24 * 5)
        let stubTrial = StubActiveTrialManager(expiresAt: expiry)
        let service = StoreKitSubscriptionService(trialManager: stubTrial)

        // No explicit refreshEntitlements() — exactly the bootstrap's call pattern.
        let entitled = await service.resolvedPremiumEntitlement()
        #expect(entitled == true)
    }

    /// `isPremiumEntitled()` is called on hot/repeated paths (ICloudSyncCoordinator calls it
    /// four times per sync; DNSProtectionViewModel calls it per state change). It must stay a
    /// cheap cached read and must NOT trigger a StoreKit round-trip, so it deliberately keeps
    /// returning the last resolved state rather than re-resolving.
    @Test("isPremiumEntitled() stays a cached read and does not force a fresh resolution")
    func isPremiumEntitledIsCachedNotResolved() async throws {
        let expiry = Date().addingTimeInterval(60 * 60 * 24 * 5)
        let stubTrial = StubActiveTrialManager(expiresAt: expiry)
        let service = StoreKitSubscriptionService(trialManager: stubTrial)

        // Cached state has not been refreshed yet, so this reports the snapshot, not truth.
        let cached = await service.isPremiumEntitled()
        #expect(cached == false)

        // After an explicit resolution the cached read agrees.
        _ = await service.refreshEntitlements()
        let afterRefresh = await service.isPremiumEntitled()
        #expect(afterRefresh == true)
    }
}

/// Trial manager stub that reports a permanently-active trial, with no keychain or
/// StoreKit dependency.
private struct StubActiveTrialManager: TrialManagerProtocol {
    let expiresAt: Date

    func status(at date: Date) async -> TrialStatus {
        .active(expiresAt: expiresAt, daysRemaining: 5)
    }

    func activateTrial(at date: Date) async -> TrialStatus {
        .active(expiresAt: expiresAt, daysRemaining: 5)
    }

    func currentEntitlement(at date: Date) async -> EntitlementState {
        .trial(expiresAt: expiresAt)
    }
}
