import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterStore: FilterStore
    private let filterPipeline: FilterPipeline
    private let updateCoordinator: UpdateCoordinator
    private let entitlementReconciler: PremiumEntitlementReconciler
    @Environment(\.scenePhase) private var scenePhase
    private let uiDependencies: AppCompositionRoot.UIDependencies
    @State private var onboardingStore = OnboardingCompletionStore()
    @State private var hasCompletedOnboarding: Bool
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system
    @State private var trialExpiryRouter = AppCompositionRoot.makeTrialExpiryRouter()
    @State private var planStateModel = AppCompositionRoot.makePlanStateModel()

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
        NSClassFromString("XCTestCase") != nil
    }

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
        let store = AppCompositionRoot.makeFilterStore()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        filterStore = store
        filterPipeline = pipeline
        updateCoordinator = AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)
        entitlementReconciler = AppCompositionRoot.makePremiumEntitlementReconciler(pipeline: pipeline, store: store)
        uiDependencies = AppCompositionRoot.makeUIDependencies(
            configuration: .mock, store: store, pipeline: pipeline, updateCoordinator: updateCoordinator
        )
        _hasCompletedOnboarding = State(initialValue: OnboardingCompletionStore().hasCompletedOnboarding)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView(dependencies: uiDependencies)
                        .fullScreenCover(isPresented: Binding(
                            get: { trialExpiryRouter.currentRoute == .showExpiredDecision },
                            set: { if !$0 { trialExpiryRouter.currentRoute = .none } }
                        )) {
                            TrialExpiredDecisionView(
                                viewModel: TrialExpiredDecisionViewModel(
                                    decisionStore: AppCompositionRoot.makeTrialDecisionStore(),
                                    notificationScheduler: AppCompositionRoot.makeTrialNotificationScheduler(),
                                    entitlementService: AppCompositionRoot.makeSubscriptionService(),
                                    onDismiss: {
                                        trialExpiryRouter.currentRoute = .none
                                    }
                                ),
                                subscriptionService: AppCompositionRoot.makeSubscriptionService()
                            )
                        }
                } else {
                    TrialOnboardingView(
                        viewModel: TrialOnboardingViewModel(
                            trialManager: AppCompositionRoot.makeTrialManager(),
                            entitlementService: AppCompositionRoot.makeSubscriptionService(),
                            notificationScheduler: AppCompositionRoot.makeTrialNotificationScheduler(),
                            onboardingStore: onboardingStore,
                            onFinish: {
                                hasCompletedOnboarding = true
                            }
                        )
                    )
                }
            }
            .preferredColorScheme(appearance.colorScheme)
            .environment(planStateModel)
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !Self.isRunningTests else { return }
                Task { await planStateModel.refresh() }
                let reconciler = entitlementReconciler
                Task.detached(priority: .utility) { await reconciler.reconcile() }
            }
            .task {
                guard !Self.isRunningTests else { return }
                // Not awaited: derivation hops to PlanStateProvider (an actor), and nothing here
                // may delay the first frame.
                planStateModel.startObserving()
                Task { await planStateModel.refresh() }
                await trialExpiryRouter.evaluateRoute()
                let pipeline = filterPipeline
                let coordinator = updateCoordinator
                let reconciler = entitlementReconciler
                let store = filterStore
                Task.detached(priority: .utility) {
                    let manifestStore = ManifestStore(filterStore: store)
                    let subscriptionService = AppCompositionRoot.makeSubscriptionService()
                    // Must be the resolved (not cached) value: it gates the bundled premium
                    // lists and is published to the Safari Web Extension, and the cached state
                    // is still `.free` this early in launch until the transaction listener's
                    // first refresh lands.
                    let entitlement = await subscriptionService.refreshEntitlements()
                    let isPremium = entitlement.hasPremiumAccess
                    await ContentBlockerBootstrap.ensureInitialRulesInstalled(
                        pipeline: pipeline, manifestStore: manifestStore, isPremiumEntitled: isPremium
                    )
                    WebExtensionBootstrap.ensureInitialWebExtensionRulesInstalled(
                        isPremium: isPremium, validUntil: entitlement.validUntil
                    )
                    _ = AppCompositionRoot.makeWebExtensionEntitlementCoordinator()
                    _ = AppCompositionRoot.makeTrialNotificationScheduler()
                    // Level-triggered: corrects any drift between installed premium filters and
                    // entitlement (missed expiry, offline refund, legacy installs), then keeps
                    // watching for live changes. Runs before the update transaction so a
                    // lapsed user never downloads premium lists.
                    await reconciler.startObserving()
                    await reconciler.reconcile()
                    let throttle = AppCompositionRoot.makeUpdateThrottle(store: store)
                    guard await throttle.shouldRun(now: Date()) else { return }
                    do {
                        let result = try await coordinator.run()
                        switch result {
                        case .upToDate, .updated:
                            try await throttle.recordSuccess(at: Date())
                        case .rolledBack, .rollbackFailed:
                            break
                        }
                    } catch {
                        // Failed launches remain retryable on the next launch.
                    }
                }
            }
        }
    }
}
