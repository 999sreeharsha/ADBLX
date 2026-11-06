import Testing
import Foundation
@testable import ADBLX

private final class StubTrialSource: TrialSource, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: TrialSnapshot
    init(_ snapshot: TrialSnapshot) { self.snapshot = snapshot }
    func set(_ snapshot: TrialSnapshot) { lock.lock(); self.snapshot = snapshot; lock.unlock() }
    func snapshot(at date: Date) async -> TrialSnapshot { lock.lock(); defer { lock.unlock() }; return snapshot }
}

private final class StubPaidSource: PaidEntitlementSource, @unchecked Sendable {
    private let lock = NSLock()
    private var kind: PremiumKind?
    init(_ kind: PremiumKind?) { self.kind = kind }
    func set(_ kind: PremiumKind?) { lock.lock(); self.kind = kind; lock.unlock() }
    func activePremiumKind() async -> PremiumKind? { lock.lock(); defer { lock.unlock() }; return kind }
}

@Suite("PlanState")
struct PlanStateValueTests {
    private let end = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("isEntitled: premium and trial are entitled; trialExpired and free are not")
    func isEntitled() {
        #expect(PlanState.premium(.subscription).isEntitled)
        #expect(PlanState.premium(.lifetime).isEntitled)
        #expect(PlanState.trial(daysRemaining: 9, endsAt: end).isEntitled)
        #expect(!PlanState.trialExpired(endedAt: end).isEntitled)
        #expect(!PlanState.free.isEntitled)
    }

    @Test("isTrialEndingSoon flips exactly at 3 days remaining", arguments: [
        (15, false), (5, false), (4, false), (3, true), (2, true), (1, true)
    ])
    func endingSoonBoundary(days: Int, expected: Bool) {
        #expect(PlanState.trial(daysRemaining: days, endsAt: end).isTrialEndingSoon == expected)
    }

    @Test("isTrialEndingSoon is false for every non-trial state")
    func endingSoonOnlyForTrial() {
        #expect(!PlanState.premium(.subscription).isTrialEndingSoon)
        #expect(!PlanState.trialExpired(endedAt: end).isTrialEndingSoon)
        #expect(!PlanState.free.isTrialEndingSoon)
    }
}

@Suite("PlanStateProvider")
struct PlanStateProviderTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let end = Date(timeIntervalSince1970: 1_900_000_000 + 4 * 86400)

    private func provider(trial: TrialSnapshot, paid: PremiumKind?) -> PlanStateProvider {
        PlanStateProvider(trial: StubTrialSource(trial), paid: StubPaidSource(paid), now: { now })
    }

    @Test("never trialed, nothing purchased -> free")
    func free() async {
        #expect(await provider(trial: .notStarted, paid: nil).current() == .free)
    }

    @Test("active trial -> trial with the source's days and end")
    func activeTrial() async {
        let state = await provider(trial: .active(endsAt: end, daysRemaining: 4), paid: nil).current()
        #expect(state == .trial(daysRemaining: 4, endsAt: end))
    }

    @Test("expired trial -> trialExpired with its end date")
    func expiredTrial() async {
        let state = await provider(trial: .expired(endedAt: end), paid: nil).current()
        #expect(state == .trialExpired(endedAt: end))
    }

    @Test("a paid entitlement wins over an active trial", arguments: [PremiumKind.subscription, .lifetime])
    func paidBeatsTrial(kind: PremiumKind) async {
        let state = await provider(trial: .active(endsAt: end, daysRemaining: 4), paid: kind).current()
        #expect(state == .premium(kind))
    }

    @Test("a paid entitlement wins over an expired trial")
    func paidBeatsExpiredTrial() async {
        let state = await provider(trial: .expired(endedAt: end), paid: .subscription).current()
        #expect(state == .premium(.subscription))
    }

    @Test("revoked subscription with a still-live trial falls back to trial")
    func revokedFallsBackToTrial() async {
        let paid = StubPaidSource(.subscription)
        let sut = PlanStateProvider(
            trial: StubTrialSource(.active(endsAt: end, daysRemaining: 4)), paid: paid, now: { now }
        )
        #expect(await sut.current() == .premium(.subscription))
        paid.set(nil)
        #expect(await sut.current() == .trial(daysRemaining: 4, endsAt: end))
    }
}

@Suite("PlanState with the real TrialManager and an injected clock")
struct PlanStateClockTests {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    private func sut(store: InMemoryTrialStore, manager: TrialManager, clock: ClockBox) -> PlanStateProvider {
        PlanStateProvider(
            trial: KeychainTrialSource(manager: manager, store: store),
            paid: StubPaidSource(nil),
            now: { clock.now }
        )
    }

    private final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    @Test("day 14 -> 1 day left; exactly day 15 -> trialExpired with the real end date")
    func expiryBoundary() async {
        let store = InMemoryTrialStore()
        let manager = TrialManager(store: store)
        _ = await manager.activateTrial(at: start)
        let clock = ClockBox(start.addingTimeInterval(14 * 86400))
        let provider = sut(store: store, manager: manager, clock: clock)

        #expect(await provider.current() == .trial(daysRemaining: 1, endsAt: start.addingTimeInterval(15 * 86400)))

        clock.now = start.addingTimeInterval(15 * 86400)
        #expect(await provider.current() == .trialExpired(endedAt: start.addingTimeInterval(15 * 86400)))
    }

    @Test("moving the clock backwards after expiry never revives the trial")
    func clockBackwardsDoesNotReviveExpiredTrial() async {
        let store = InMemoryTrialStore()
        let manager = TrialManager(store: store)
        _ = await manager.activateTrial(at: start)
        let clock = ClockBox(start.addingTimeInterval(20 * 86400))
        let provider = sut(store: store, manager: manager, clock: clock)
        guard case .trialExpired = await provider.current() else { Issue.record("expected expired"); return }

        clock.now = start.addingTimeInterval(1 * 86400)   // user sets the clock back to day 1
        guard case .trialExpired = await provider.current() else {
            Issue.record("clock moved backwards revived an expired trial"); return
        }
    }

    @Test("moving the clock backwards mid-trial never increases the days remaining")
    func clockBackwardsDoesNotExtendActiveTrial() async {
        let store = InMemoryTrialStore()
        let manager = TrialManager(store: store)
        _ = await manager.activateTrial(at: start)
        let clock = ClockBox(start.addingTimeInterval(10 * 86400))
        let provider = sut(store: store, manager: manager, clock: clock)
        guard case .trial(let before, _) = await provider.current() else { Issue.record("expected trial"); return }
        #expect(before == 5)

        clock.now = start.addingTimeInterval(2 * 86400)   // clock moved back 8 days
        guard case .trial(let after, _) = await provider.current() else { Issue.record("expected trial"); return }
        #expect(after <= before, "days remaining grew from \(before) to \(after) after the clock moved backwards")
    }
}

@Suite("PlanStateModel")
@MainActor
struct PlanStateModelTests {
    private let end = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("starts unresolved, and refresh resolves it from the provider")
    func resolves() async {
        let trial = StubTrialSource(.active(endsAt: end, daysRemaining: 9))
        let model = PlanStateModel(
            provider: PlanStateProvider(trial: trial, paid: StubPaidSource(nil), now: { Date() }),
            entitlementService: MockSubscriptionService(state: .free)
        )
        #expect(!model.isResolved)
        await model.refresh()
        #expect(model.isResolved)
        #expect(model.state == .trial(daysRemaining: 9, endsAt: end))
    }

    @Test("an entitlement change re-derives the plan state without a manual refresh")
    func entitlementChangeRefreshes() async throws {
        let paid = StubPaidSource(nil)
        let entitlement = MockSubscriptionService(state: .free)
        let model = PlanStateModel(
            provider: PlanStateProvider(trial: StubTrialSource(.notStarted), paid: paid, now: { Date() }),
            entitlementService: entitlement
        )
        model.startObserving()
        await model.refresh()
        #expect(model.state == .free)

        paid.set(.lifetime)
        entitlement.updateState(.lifetime)
        for _ in 0..<50 where model.state != .premium(.lifetime) { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(model.state == .premium(.lifetime))
        model.stopObserving()
    }
}

@Suite("StoreKit product -> PremiumKind")
struct PremiumKindMappingTests {
    @Test("subscription and lifetime product IDs map correctly; unknown IDs map to nil")
    func mapping() {
        #expect(StoreKitSubscriptionService.premiumKind(forProductID: StoreKitSubscriptionService.monthlyProductID) == .subscription)
        #expect(StoreKitSubscriptionService.premiumKind(forProductID: StoreKitSubscriptionService.annualProductID) == .subscription)
        #expect(StoreKitSubscriptionService.premiumKind(forProductID: StoreKitSubscriptionService.lifetimeProductID) == .lifetime)
        #expect(StoreKitSubscriptionService.premiumKind(forProductID: "com.example.other") == nil)
    }
}

#if DEBUG
@Suite("PlanState debug override")
@MainActor
struct PlanStateDebugOverrideTests {
    private func makeModel() -> PlanStateModel {
        PlanStateModel(
            provider: PlanStateProvider(trial: StubTrialSource(.notStarted), paid: StubPaidSource(nil), now: { Date() }),
            entitlementService: MockSubscriptionService(state: .free)
        )
    }

    @Test("an override replaces the derived plan, and clearing it restores the real one")
    func overrideAndClear() async {
        let model = makeModel()
        await model.refresh()
        #expect(model.state == .free)

        await model.setDebugOverride(.premium(.lifetime))
        #expect(model.state == .premium(.lifetime))

        await model.refresh()
        #expect(model.state == .premium(.lifetime), "a refresh keeps the override")

        await model.setDebugOverride(nil)
        #expect(model.state == .free)
    }

    @Test("each option maps to its own plan state")
    func optionMapping() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let states = DebugPlanOverride.allCases.map { $0.state(now: now) }
        #expect(states == [
            .premium(.subscription), .premium(.lifetime),
            .trial(daysRemaining: 9, endsAt: now.addingTimeInterval(9 * 86_400)),
            .trial(daysRemaining: 2, endsAt: now.addingTimeInterval(2 * 86_400)),
            .trialExpired(endedAt: now.addingTimeInterval(-86_400)),
            .free
        ])
    }
}
#endif
