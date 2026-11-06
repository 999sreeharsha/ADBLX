import Testing
import Foundation
import UIKit
@testable import ADBLX

@Suite("Entitlement resolution", .serialized)
struct EntitlementResolutionTests {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    private func expiredTrial() -> TrialManager {
        TrialManager(store: InMemoryTrialStore(record: TrialRecord(
            activatedAt: start.addingTimeInterval(-40 * 86400), lastObservedDate: start, isExpired: true
        )))
    }

    private func activeTrial() -> TrialManager {
        TrialManager(store: InMemoryTrialStore(record: TrialRecord(activatedAt: Date(), lastObservedDate: Date())))
    }

    private func service(
        _ source: FakeStoreEntitlementSource,
        trial: TrialManager? = nil,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> StoreKitSubscriptionService {
        StoreKitSubscriptionService(
            trialManager: trial ?? expiredTrial(), entitlementSource: source,
            notificationCenter: notificationCenter
        )
    }

    // MARK: 1. Paid always wins over trial / continue-free

    @Test("expired trial + active annual -> entitled (annual)")
    func expiredTrialPlusAnnual() async {
        let sut = service(FakeStoreEntitlementSource([.annual()]))
        let state = await sut.refreshEntitlements()
        guard case .annual = state else { Issue.record("expected .annual, got \(state)"); return }
        #expect(await sut.isPremiumEntitled())
    }

    @Test("expired trial + lifetime -> entitled (lifetime)")
    func expiredTrialPlusLifetime() async {
        let sut = service(FakeStoreEntitlementSource([.lifetime()]))
        #expect(await sut.refreshEntitlements() == .lifetime)
        #expect(await sut.isPremiumEntitled())
    }

    @Test("active trial + annual -> annual (paid outranks trial)")
    func paidOutranksActiveTrial() async {
        let sut = service(FakeStoreEntitlementSource([.annual()]), trial: activeTrial())
        guard case .annual = await sut.refreshEntitlements() else { Issue.record("expected .annual"); return }
    }

    @Test("expired trial and nothing purchased -> free")
    func expiredTrialAloneIsFree() async {
        #expect(await service(FakeStoreEntitlementSource()).refreshEntitlements() == .free)
    }

    @Test("'continue free' + purchase -> entitled, and the expiry router stands down")
    func continueFreeThenPurchase() async {
        let source = FakeStoreEntitlementSource()
        let sut = service(source)
        let decisions = InMemoryTrialDecisionStore()
        try? await decisions.setChosenFreeTier(true)
        let router = await TrialExpiryRouter(entitlementService: sut, trialManager: expiredTrial(), decisionStore: decisions)

        await router.evaluateRoute()
        #expect(await router.currentRoute == .none)           // chose free, so no full-screen

        source.setEntitlements([.annual()])
        await sut.refreshEntitlements()
        #expect(await sut.isPremiumEntitled())
        await router.evaluateRoute()
        #expect(await router.currentRoute == .none)
    }

    // MARK: 2. Refresh ordering, Transaction.updates, purchase flow

    @Test("a slow refresh that started before the purchase cannot overwrite the newer entitled state")
    func staleRefreshCannotOverwriteNewerState() async {
        // StoreKit now reports the purchase, but the FIRST read (begun before it, so it saw nothing)
        // is slow and returns stale []. Every later read returns the annual entitlement.
        let source = FakeStoreEntitlementSource([.annual()])
        source.setScript([.init(entitlements: [], delayNanoseconds: 300_000_000)])
        let sut = service(source)

        async let first = sut.refreshEntitlements()
        try? await Task.sleep(nanoseconds: 50_000_000)
        async let second = sut.refreshEntitlements()
        _ = await (first, second)

        guard case .annual = await sut.currentState else {
            Issue.record("stale refresh won: state is \(await sut.currentState)"); return
        }
    }

    @Test("Transaction.updates: an update flips state, publishes it, and finishes the transaction — no relaunch", .timeLimit(.minutes(1)))
    func updateStreamRefreshesAndFinishes() async throws {
        let source = FakeStoreEntitlementSource()
        let sut = service(source)
        var states = await sut.stateUpdates().makeAsyncIterator()
        #expect(await states.next() == .free)

        source.setEntitlements([.annual(id: 77)])
        // An update sent before the listener attaches goes nowhere.
        await source.wait { $0.isListening }
        source.emitUpdate(.annual(id: 77))

        let next = await states.next()
        guard case .annual = next else { Issue.record("expected .annual from the stream, got \(String(describing: next))"); return }
        await source.wait { !$0.finished.isEmpty }
        #expect(source.finished == [77])
    }

    @Test("purchase(): verified success -> true, entitled, transaction finished, state published")
    func purchaseSuccess() async throws {
        let source = FakeStoreEntitlementSource()
        source.purchaseOutcome = .success(.annual(id: 5))
        let sut = service(source)
        var states = await sut.stateUpdates().makeAsyncIterator()
        _ = await states.next()                                   // initial .free

        #expect(try await sut.purchase("annual"))
        guard case .annual = await states.next() else { Issue.record("no .annual on the stream"); return }
        #expect(await sut.isPremiumEntitled())
        #expect(source.finished == [5])
    }

    @Test("purchase(): cancelled and pending stay free and return false")
    func purchaseCancelledOrPending() async throws {
        for outcome in [StorePurchaseOutcome.cancelled, .pending] {
            let source = FakeStoreEntitlementSource()
            source.purchaseOutcome = outcome
            let sut = service(source)
            #expect(try await sut.purchase("annual") == false)
            #expect(await sut.currentState == .free)
        }
    }

    @Test("a purchase reaches PlanStateModel and the reconciler without a relaunch")
    @MainActor
    func purchaseDrivesPlanStateAndReconciler() async throws {
        let source = FakeStoreEntitlementSource()
        let sut = service(source)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("PurchaseFlow_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let ids = GroupExtensionIdentifiers(
            ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
            annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
        )
        let store = FilterStore(overrideBaseURL: temp)
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: NativeRuleCompilerAdapter(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let reconciler = PremiumEntitlementReconciler(
            store: store, pipeline: pipeline, manifestStore: ManifestStore(filterStore: store),
            reloader: ReloadCoordinator(), extensionIdentifiers: ids, entitlementService: sut
        )
        let model = PlanStateModel(
            provider: PlanStateProvider(trial: KeychainTrialSource(manager: expiredTrial(), store: InMemoryTrialStore()),
                                        paid: sut),
            entitlementService: sut
        )
        await reconciler.startObserving()
        model.startObserving()
        await model.refresh()
        guard case .trialExpired = model.state else { Issue.record("expected .trialExpired, got \(model.state)"); return }

        source.purchaseOutcome = .success(.annual(id: 9))
        #expect(try await sut.purchase("annual"))

        for _ in 0..<150 where model.state != .premium(.subscription) { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(model.state == .premium(.subscription))

        var restored = false
        for _ in 0..<150 where !restored {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let data = try? await store.read("installed_filters.json", in: .metadata),
               let installed = try? JSONDecoder().decode([InstalledFilter].self, from: data) {
                restored = installed.contains { $0.id == "fanboy-annoyances" && $0.premium == true }
            }
        }
        #expect(restored, "Annoyances was not reinstalled after the purchase")
        await reconciler.stopObserving()
        model.stopObserving()
    }

    // MARK: Unverified / revoked

    @Test("purchase(): an unverified transaction throws (visible to the user), stays free, and is not finished")
    func unverifiedPurchaseThrows() async {
        let source = FakeStoreEntitlementSource()
        source.purchaseOutcome = .success(.annual(id: 3).with(verification: .unverified("invalidCertificateChain")))
        let sut = service(source)

        await #expect(throws: SubscriptionPurchaseError.self) { try await sut.purchase("annual") }
        #expect(await sut.currentState == .free)
        #expect(source.finished.isEmpty)
    }

    @Test("an unverified entitlement is never granted, in any build")
    func unverifiedNeverGranted() async {
        let source = FakeStoreEntitlementSource([.annual().with(verification: .unverified("invalidSignature"))])
        let sut = service(source)
        #expect(await sut.refreshEntitlements() == .free)
        let snap = await sut.snapshot()
        #expect(snap.unverifiedErrors == ["invalidSignature"])
        #expect(snap.verifiedCount == 0)
    }

    @Test("an unverified update from Transaction.updates is neither granted nor finished", .timeLimit(.minutes(1)))
    func unverifiedUpdateNotFinished() async throws {
        let unverified = StoreEntitlement.annual(id: 41).with(verification: .unverified("invalidCertificateChain"))
        let source = FakeStoreEntitlementSource([unverified])
        let sut = service(source)
        await sut.refreshEntitlements()
        let readsBefore = source.readCount

        await source.wait { $0.isListening }
        source.emitUpdate(unverified)
        await source.wait { $0.readCount > readsBefore }

        #expect(source.readCount > readsBefore, "the update did not trigger a refresh")
        #expect(await sut.currentState == .free)
        #expect(source.finished.isEmpty)
    }

    @Test("a revoked entitlement is not granted")
    func revokedNotGranted() async {
        let sut = service(FakeStoreEntitlementSource([.annual().with(revoked: Date())]))
        #expect(await sut.refreshEntitlements() == .free)
    }

    // MARK: 4. One resolved entitlement, read by every consumer

    // Every service observes the foreground notification, so one posted by anything else in the
    // test process (the host app activating mid-run) used to add a StoreKit read and fail
    // `singleSourceOfTruth` intermittently.
    @Test("a foreground notification on the service's own center refreshes it")
    func ownForegroundNotificationRefreshes() async {
        let center = NotificationCenter()
        let source = FakeStoreEntitlementSource([.annual()])
        let sut = service(source, notificationCenter: center)
        await sut.refreshEntitlements()
        let readsAfterRefresh = source.readCount

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await source.wait { $0.readCount > readsAfterRefresh }

        #expect(source.readCount > readsAfterRefresh, "coming to the foreground did not refresh entitlements")
    }

    @Test("a foreground notification posted elsewhere does not make a test's service re-read StoreKit")
    func strayForegroundNotificationIsIgnored() async throws {
        let source = FakeStoreEntitlementSource([.annual()])
        let sut = service(source)
        await source.wait { $0.isListening }   // the listener's own startup refresh is done
        await sut.refreshEntitlements()
        let readsAfterRefresh = source.readCount

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))

        #expect(source.readCount == readsAfterRefresh, "a stray foreground notification caused a StoreKit read")
    }

    @Test("DNS gate, PlanStateProvider and the reconciler's entitlement read agree and never re-query StoreKit")
    func singleSourceOfTruth() async {
        let source = FakeStoreEntitlementSource([.annual()])
        let sut = service(source)
        // The service refreshes once itself at startup, on a background task. Without waiting for
        // it, that read can land after `readsAfterRefresh` is taken and look like a re-query.
        await source.wait { $0.isListening }
        await sut.refreshEntitlements()
        let readsAfterRefresh = source.readCount

        let provider = PlanStateProvider(
            trial: KeychainTrialSource(manager: expiredTrial(), store: InMemoryTrialStore()), paid: sut
        )
        #expect(await sut.isPremiumEntitled())                                   // DNS gate
        #expect(await provider.current() == .premium(.subscription))             // plan state
        #expect(source.readCount == readsAfterRefresh, "PlanStateProvider/DNS gate queried StoreKit on their own")

        // StoreKit changes underneath; until the service refreshes, every consumer must still agree.
        source.setEntitlements([])
        #expect(await sut.isPremiumEntitled() == (await provider.current()).isEntitled)
        await sut.refreshEntitlements()                                          // reconciler path
        #expect(await sut.isPremiumEntitled() == false)
        #expect(await provider.current().isEntitled == false)
    }
}
