import Foundation
import Testing
@testable import ADBLX

/// Blocker checks wait their turn in `ContentBlockerCallGate`, and the store's prices come from
/// StoreKit, so the plan card shows at once and its breakdown and prices fill in afterwards.
@MainActor
@Suite("Home plan card while its details load", .timeLimit(.minutes(1)))
struct HomePlanCardLoadingTests {
    nonisolated final class InMemoryDismissalStore: PlanCardDismissalStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var stored = HomePlanDismissals()
        func load() -> HomePlanDismissals { lock.withLock { stored } }
        func save(_ dismissals: HomePlanDismissals) { lock.withLock { stored = dismissals } }
    }

    /// Store prices that arrive only when the test says so.
    nonisolated final class HeldSubscriptionService: @unchecked Sendable {
        private let gate = AsyncStream.makeStream(of: Void.self)
        let requested = TestSignal<Void>()

        func release() { gate.continuation.finish() }
    }

    private let ads = AppCompositionRoot.extensionIdentifiers[.ads]
    private let ended = PlanState.trialExpired(endedAt: Date(timeIntervalSince1970: 1_800_000_000))

    private func makeViewModel(
        manager: ContentBlockerCallGateTests.FakeContentBlockerManager,
        subscriptionService: SubscriptionService = MockSubscriptionService()
    ) -> HomePlanCardViewModel {
        HomePlanCardViewModel(
            dismissalStore: InMemoryDismissalStore(),
            stateProvider: SystemContentBlockerStateProvider(
                timeoutSeconds: 30, gate: ContentBlockerCallGate(), stateOperation: manager.stateOperation
            ),
            extensionIdentifiers: AppCompositionRoot.extensionIdentifiers,
            subscriptionService: subscriptionService,
            dnsAvailable: false
        )
    }

    @Test("the protection card shows while a blocker check is held in the gate; its breakdown fills in after")
    func cardShowsWhileCheckIsHeld() async {
        let manager = ContentBlockerCallGateTests.FakeContentBlockerManager(held: [ads])
        let viewModel = makeViewModel(manager: manager)

        let refresh = Task { await viewModel.refresh(plan: ended, isResolved: true) }
        await manager.invoked.wait { $0 == ads }

        #expect(viewModel.presentation == .protectionCard)
        #expect(viewModel.breakdown == nil)

        manager.release(ads, isEnabled: true)
        await refresh.value
        #expect(viewModel.presentation == .protectionCard)
        #expect(viewModel.breakdown == ProtectionBreakdown.make(plan: ended, safariProtectionEnabled: true, dnsAvailable: false))
    }

    @Test("the card shows before the store's prices arrive; they fill in after")
    func cardShowsBeforePrices() async {
        let manager = ContentBlockerCallGateTests.FakeContentBlockerManager()
        let store = HeldSubscriptionService()
        let viewModel = makeViewModel(manager: manager, subscriptionService: store)

        let refresh = Task { await viewModel.refresh(plan: .free, isResolved: true) }
        await store.requested.wait { _ in true }

        #expect(viewModel.presentation == .freePlanCard)
        #expect(viewModel.prices == PlanPrices())

        store.release()
        await refresh.value
        #expect(viewModel.prices.annual == "₹999")
    }

    @Test("a plan change while details load replaces the card at once, and the late details are dropped")
    func planChangeReplacesCardAtOnce() async {
        let manager = ContentBlockerCallGateTests.FakeContentBlockerManager(held: [ads])
        let viewModel = makeViewModel(manager: manager)

        let first = Task { await viewModel.refresh(plan: ended, isResolved: true) }
        await manager.invoked.wait { $0 == ads }
        #expect(viewModel.presentation == .protectionCard)

        await viewModel.refresh(plan: .premium(.lifetime), isResolved: true)
        #expect(viewModel.presentation == .hidden)

        manager.release(ads, isEnabled: true)
        await first.value
        #expect(viewModel.presentation == .hidden)
        #expect(viewModel.breakdown == nil)
    }
}

extension HomePlanCardLoadingTests.HeldSubscriptionService: SubscriptionService {
    func fetchStatus() async -> SubscriptionStatus {
        requested.send(())
        for await _ in gate.stream { break }
        return SubscriptionStatus(isPremium: false, plans: [
            SubscriptionPlan(id: "annual", name: "Annual", priceDescription: "₹999", billingPeriodDescription: "per year", isCurrentPlan: false)
        ])
    }

    func purchase(_ planID: String) async throws -> Bool { false }
    func restorePurchases() async throws {}
}
