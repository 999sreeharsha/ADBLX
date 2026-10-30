// ADBLX/Features/Premium/PremiumViewModel.swift
import Observation
import enum StoreKit.StoreKitError

@Observable
final class PremiumViewModel {
    enum RestoreOutcome: Equatable {
        case restored
        case nothingToRestore
        /// The App Store had not answered within `restoreTimeout`. The sync keeps running;
        /// a purchase it finds is applied when it finishes or via `Transaction.updates`.
        case stillWaiting
    }

    private let service: SubscriptionService
    private let restoreTimeout: Duration

    /// The locked feature that opened this paywall, if any.
    let focus: PremiumFeature?
    var status: SubscriptionStatus?
    var isLoading = false
    var purchaseError: Error?
    var restoreOutcome: RestoreOutcome?
    var isRestoring = false

    init(service: SubscriptionService, focus: PremiumFeature? = nil, restoreTimeout: Duration = .seconds(30)) {
        self.service = service
        self.focus = focus
        self.restoreTimeout = restoreTimeout
    }

    func load() async {
        isLoading = true
        status = await service.fetchStatus()
        isLoading = false
    }

    func purchase(planID: String) async {
        purchaseError = nil
        do {
            _ = try await service.purchase(planID)
            status = await service.fetchStatus()
        } catch {
            purchaseError = error
        }
    }

    /// Restores purchases, never waiting longer than `restoreTimeout`. Past the timeout the
    /// sync keeps running and its result is applied when it finishes. Cancelling the App
    /// Store sign-in is not an error.
    func restore() async {
        isRestoring = true
        purchaseError = nil
        restoreOutcome = nil
        defer { isRestoring = false }

        let service = service
        let work = Task { () async throws -> SubscriptionStatus in
            try await service.restorePurchases()
            return await service.fetchStatus()
        }
        switch await Self.race(work, timeout: restoreTimeout) {
        case .some(let result):
            apply(result)
        case .none:
            restoreOutcome = .stillWaiting
            Task { [weak self] in
                let result = await work.result
                self?.applyLate(result)
            }
        }
    }

    private func apply(_ result: Result<SubscriptionStatus, Error>) {
        switch result {
        case .success(let newStatus):
            status = newStatus
            restoreOutcome = newStatus.isPremium ? .restored : .nothingToRestore
        case .failure(let error) where Self.isUserCancellation(error):
            break
        case .failure(let error):
            purchaseError = error
        }
    }

    /// A result arriving after the timeout only ever upgrades the screen: errors and
    /// "nothing found" stay quiet because the user has already been told to wait.
    private func applyLate(_ result: Result<SubscriptionStatus, Error>) {
        guard case .success(let newStatus) = result else { return }
        status = newStatus
        if newStatus.isPremium {
            restoreOutcome = .restored
        }
    }

    private static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .userCancelled = error as? StoreKitError { return true }
        return false
    }

    /// The task's result, or nil if `timeout` elapses first. The task is not cancelled.
    private static func race(
        _ work: Task<SubscriptionStatus, Error>,
        timeout: Duration
    ) async -> Result<SubscriptionStatus, Error>? {
        let (stream, continuation) = AsyncStream.makeStream(of: Result<SubscriptionStatus, Error>?.self)
        Task { continuation.yield(await work.result) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(nil)
        }
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next() ?? nil
        timer.cancel()
        continuation.finish()
        return first
    }
}
