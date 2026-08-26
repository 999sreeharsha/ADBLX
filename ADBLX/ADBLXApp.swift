import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterStore: FilterStore
    private let filterPipeline: FilterPipeline
    private let updateCoordinator: UpdateCoordinator
    private let uiDependencies: AppCompositionRoot.UIDependencies
    private let appearanceStore = AppearancePreferenceStore()
    @State private var onboardingStore = OnboardingCompletionStore()
    @State private var hasCompletedOnboarding: Bool
    @State private var appearance: AppearancePreference
    @State private var trialExpiryRouter = AppCompositionRoot.makeTrialExpiryRouter()

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
        uiDependencies = AppCompositionRoot.makeUIDependencies(
            configuration: .mock, store: store, pipeline: pipeline, updateCoordinator: updateCoordinator
        )
        _hasCompletedOnboarding = State(initialValue: OnboardingCompletionStore().hasCompletedOnboarding)
        _appearance = State(initialValue: appearanceStore.current)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView(dependencies: uiDependencies, appearance: $appearance)
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
            .task {
                guard !Self.isRunningTests else { return }
                await trialExpiryRouter.evaluateRoute()
                let pipeline = filterPipeline
                let coordinator = updateCoordinator
                let store = filterStore
                Task.detached(priority: .utility) {
                    let manifestStore = ManifestStore(filterStore: store)
                    await ContentBlockerBootstrap.ensureInitialRulesInstalled(
                        pipeline: pipeline, manifestStore: manifestStore
                    )
                    let subscriptionService = AppCompositionRoot.makeSubscriptionService()
                    let isPremium = await subscriptionService.isPremiumEntitled()
                    WebExtensionBootstrap.ensureInitialWebExtensionRulesInstalled(isPremium: isPremium)
                    _ = AppCompositionRoot.makeWebExtensionEntitlementCoordinator()
                    _ = AppCompositionRoot.makeTrialNotificationScheduler()
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
