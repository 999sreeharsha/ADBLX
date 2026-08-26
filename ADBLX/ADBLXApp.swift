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

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
        let store = AppCompositionRoot.makeFilterStore()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        filterStore = store
        filterPipeline = pipeline
        updateCoordinator = AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)
        uiDependencies = AppCompositionRoot.makeUIDependencies(
            configuration: .mock, store: store, updateCoordinator: updateCoordinator
        )
        _hasCompletedOnboarding = State(initialValue: OnboardingCompletionStore().hasCompletedOnboarding)
        _appearance = State(initialValue: appearanceStore.current)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView(dependencies: uiDependencies, appearance: $appearance)
                } else {
                    OnboardingView {
                        onboardingStore.hasCompletedOnboarding = true
                        hasCompletedOnboarding = true
                    }
                }
            }
            .preferredColorScheme(appearance.colorScheme)
            .task {
                let pipeline = filterPipeline
                let coordinator = updateCoordinator
                let store = filterStore
                Task.detached(priority: .utility) {
                    let manifestStore = ManifestStore(filterStore: store)
                    await ContentBlockerBootstrap.ensureInitialRulesInstalled(
                        pipeline: pipeline, manifestStore: manifestStore
                    )
                    WebExtensionBootstrap.ensureInitialWebExtensionRulesInstalled()
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
