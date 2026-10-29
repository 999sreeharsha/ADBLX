import Foundation
import Observation

/// The one observable plan state, owned by the composition root and injected into the view
/// hierarchy. Derivation runs in `PlanStateProvider` (an actor), so refreshing never blocks
/// the main thread. Nothing awaits this before the first frame: until the first `refresh()`
/// completes `isResolved` is false and `state` is the neutral `.free`; views that would show
/// a plan-specific message should render nothing (or a placeholder) until `isResolved`.
@MainActor
@Observable
final class PlanStateModel {
    private(set) var state: PlanState = .free
    private(set) var isResolved = false

    @ObservationIgnored private let provider: PlanStateProvider
    @ObservationIgnored private let entitlementService: EntitlementService
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(provider: PlanStateProvider, entitlementService: EntitlementService) {
        self.provider = provider
        self.entitlementService = entitlementService
    }

    func refresh() async {
        let derived = await provider.current()
        if derived != state { state = derived }
        isResolved = true
    }

    /// Re-derives whenever entitlement changes (purchase, lapse, refund while open).
    func startObserving() {
        guard observationTask == nil else { return }
        let service = entitlementService
        observationTask = Task { [weak self] in
            for await _ in service.stateUpdates() {
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }
}
