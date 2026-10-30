import Testing
import Foundation
import enum StoreKit.StoreKitError
@testable import ADBLX

@Suite("Premium paywall (Phase 4a)")
struct PremiumPaywallTests {
    private let date = Date(timeIntervalSince1970: 1_900_000_000)
    private let formatDate: (Date) -> String = { _ in "<date>" }

    // MARK: Header

    @Test("header wording per plan state")
    func headerText() {
        #expect(PlanStateDisplay.premiumHeaderText(for: .trial(daysRemaining: 4, endsAt: date), formatDate: formatDate)
                == String(format: String(localized: "premium.header.trialEnds"), "<date>"))
        #expect(PlanStateDisplay.premiumHeaderText(for: .trialExpired(endedAt: date), formatDate: formatDate)
                == String(format: String(localized: "premium.header.trialEnded"), "<date>"))
        #expect(PlanStateDisplay.premiumHeaderText(for: .premium(.subscription), formatDate: formatDate)
                == String(localized: "premium.header.subscription"))
        #expect(PlanStateDisplay.premiumHeaderText(for: .premium(.lifetime), formatDate: formatDate)
                == String(localized: "premium.header.lifetime"))
        #expect(PlanStateDisplay.premiumHeaderText(for: .free, formatDate: formatDate)
                == String(localized: "premium.header.free"))
    }

    @Test("header strings are real localizations, not echoed keys, and carry the date")
    func headerStringsResolve() {
        let ends = PlanStateDisplay.premiumHeaderText(for: .trial(daysRemaining: 4, endsAt: date), formatDate: formatDate)
        let ended = PlanStateDisplay.premiumHeaderText(for: .trialExpired(endedAt: date), formatDate: formatDate)
        #expect(ends.contains("<date>") && !ends.hasPrefix("premium."))
        #expect(ended.contains("<date>") && !ended.hasPrefix("premium."))
        #expect(ends != ended)
    }

    // MARK: Focus

    @Test("a focused paywall lists the focused feature first; unfocused keeps the default order")
    func focusOrdersFeatures() {
        #expect(PremiumFeature.displayOrder(focus: nil) == [.dnsProtection, .premiumFilterLists, .backgroundUpdates, .youtube])
        #expect(PremiumFeature.displayOrder(focus: .premiumFilterLists)
                == [.premiumFilterLists, .dnsProtection, .backgroundUpdates, .youtube])
        #expect(PremiumFeature.displayOrder(focus: .youtube) == [.youtube, .dnsProtection, .premiumFilterLists, .backgroundUpdates])
    }

    @Test("PremiumViewModel carries the focus it was opened with")
    func viewModelFocus() {
        let service = PaywallStubService(statusToReturn: SubscriptionStatus(isPremium: false, plans: []))
        #expect(PremiumViewModel(service: service).focus == nil)
        #expect(PremiumViewModel(service: service, focus: .dnsProtection).focus == .dnsProtection)
    }

    @Test("a premium filter list is locked only while not entitled, and opens the filter-lists focus")
    func lockedFilterList() {
        let premium = FilterListEntry(id: "fanboy-annoyances", name: "Annoyances", category: .annoyances,
                                      version: "1", isEnabled: false, isPremium: true)
        let free = FilterListEntry(id: "easylist", name: "EasyList", category: .ads,
                                   version: "1", isEnabled: true, isPremium: false)
        #expect(PremiumFeature.lockedFeature(for: premium, isEntitled: false) == .premiumFilterLists)
        #expect(PremiumFeature.lockedFeature(for: premium, isEntitled: true) == nil)
        #expect(PremiumFeature.lockedFeature(for: free, isEntitled: false) == nil)
    }

    // MARK: Restore

    @Test("restore reports .restored when it leaves the user Premium")
    func restoreRestored() async {
        let viewModel = PremiumViewModel(service: PaywallStubService(
            statusToReturn: SubscriptionStatus(isPremium: true, plans: [])
        ))
        await viewModel.restore()
        #expect(viewModel.restoreOutcome == .restored)
    }

    @Test("restore reports .nothingToRestore when it finds nothing")
    func restoreNothing() async {
        let viewModel = PremiumViewModel(service: PaywallStubService(
            statusToReturn: SubscriptionStatus(isPremium: false, plans: [])
        ))
        await viewModel.restore()
        #expect(viewModel.restoreOutcome == .nothingToRestore)
    }

    @Test("a failed restore surfaces the error and no outcome")
    func restoreFails() async {
        let viewModel = PremiumViewModel(service: PaywallStubService(statusToReturn: SubscriptionStatus(isPremium: false, plans: []), restoreFails: true))
        await viewModel.restore()
        #expect(viewModel.restoreOutcome == nil)
        #expect(viewModel.purchaseError != nil)
    }

    @Test("cancelling the App Store sign-in is a silent no-op")
    func restoreCancelledIsSilent() async {
        let viewModel = PremiumViewModel(service: PaywallStubService(
            statusToReturn: SubscriptionStatus(isPremium: false, plans: []), restoreError: StoreKitError.userCancelled
        ))
        await viewModel.restore()
        #expect(viewModel.restoreOutcome == nil)
        #expect(viewModel.purchaseError == nil)
        #expect(!viewModel.isRestoring)
    }

    @Test("restore shows progress while it runs and clears it when done")
    func restoreShowsProgress() async {
        let gate = RestoreGate()
        let viewModel = PremiumViewModel(service: PaywallStubService(
            statusToReturn: SubscriptionStatus(isPremium: true, plans: []), gate: gate
        ))
        let restore = Task { await viewModel.restore() }
        await gate.waitUntilEntered()
        #expect(viewModel.isRestoring)
        await gate.open()
        await restore.value
        #expect(!viewModel.isRestoring)
        #expect(viewModel.restoreOutcome == .restored)
    }

    @Test("a restore that outlasts the timeout stops waiting without failing")
    func restoreTimesOut() async {
        let gate = RestoreGate()
        let viewModel = PremiumViewModel(
            service: PaywallStubService(statusToReturn: SubscriptionStatus(isPremium: true, plans: []), gate: gate),
            restoreTimeout: .milliseconds(50)
        )
        await viewModel.restore()
        #expect(viewModel.restoreOutcome == .stillWaiting)
        #expect(viewModel.purchaseError == nil)
        #expect(!viewModel.isRestoring)
        await gate.open()
    }

    @Test("a restore that finishes after the timeout still applies its result")
    func lateRestoreApplies() async {
        let gate = RestoreGate()
        let viewModel = PremiumViewModel(
            service: PaywallStubService(statusToReturn: SubscriptionStatus(isPremium: true, plans: []), gate: gate),
            restoreTimeout: .milliseconds(50)
        )
        await viewModel.restore()
        #expect(viewModel.restoreOutcome == .stillWaiting)
        await gate.open()
        for _ in 0..<200 where viewModel.restoreOutcome != .restored {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.restoreOutcome == .restored)
        #expect(viewModel.status?.isPremium == true)
    }

    @Test("the still-waiting message is a real localization")
    func stillWaitingStringResolves() {
        #expect(!String(localized: "premium.restore.stillWaiting").hasPrefix("premium."))
        #expect(!String(localized: "premium.restore.inProgress").hasPrefix("premium."))
    }
}

/// Parks `restorePurchases()` until `open()`, so tests control when a restore finishes.
private actor RestoreGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct PaywallStubService: SubscriptionService {
    struct RestoreError: Error {}
    let statusToReturn: SubscriptionStatus
    var restoreFails = false
    var restoreError: (any Error)?
    var gate: RestoreGate?
    func fetchStatus() async -> SubscriptionStatus { statusToReturn }
    func purchase(_ planID: String) async throws -> Bool { true }
    func restorePurchases() async throws {
        await gate?.pass()
        if let restoreError { throw restoreError }
        if restoreFails { throw RestoreError() }
    }
}
