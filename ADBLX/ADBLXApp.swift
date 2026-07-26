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
        _appearance = State(initialValue: AppearancePreferenceStore().current)
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
                Task.detached(priority: .utility) {
                    await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: pipeline)
                }
            }
        }
    }
}
