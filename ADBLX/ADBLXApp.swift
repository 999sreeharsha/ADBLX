import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterStore: FilterStore
    private let filterPipeline: FilterPipeline
    private let uiDependencies: AppCompositionRoot.UIDependencies
    @State private var onboardingStore = OnboardingCompletionStore()
    @State private var hasCompletedOnboarding: Bool

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
        let store = AppCompositionRoot.makeFilterStore()
        filterStore = store
        filterPipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        uiDependencies = AppCompositionRoot.makeMockUIDependencies()
        _hasCompletedOnboarding = State(initialValue: OnboardingCompletionStore().hasCompletedOnboarding)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView(dependencies: uiDependencies)
                } else {
                    OnboardingView {
                        onboardingStore.hasCompletedOnboarding = true
                        hasCompletedOnboarding = true
                    }
                }
            }
            .task {
                let pipeline = filterPipeline
                Task.detached(priority: .utility) {
                    await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: pipeline)
                }
            }
        }
    }
}
