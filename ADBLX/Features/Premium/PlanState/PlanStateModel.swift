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

    #if DEBUG
    /// Forced by the Developer screen; `nil` shows the real plan. Display only.
    private(set) var debugOverride: PlanState?
    #endif

    @ObservationIgnored private let provider: PlanStateProvider
    @ObservationIgnored private let entitlementService: EntitlementService
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(provider: PlanStateProvider, entitlementService: EntitlementService) {
        self.provider = provider
        self.entitlementService = entitlementService
    }

    func refresh() async {
        var derived = await provider.current()
        #if DEBUG
        if let debugOverride { derived = debugOverride }
        #endif
        if derived != state { state = derived }
        isResolved = true
    }

    #if DEBUG
    func setDebugOverride(_ state: PlanState?) async {
        debugOverride = state
        await refresh()
    }
    #endif

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
