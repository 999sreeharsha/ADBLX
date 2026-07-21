import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterPipeline = AppCompositionRoot.makeFilterPipeline()
    private let uiDependencies = AppCompositionRoot.makeMockUIDependencies()

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(dependencies: uiDependencies)
                .task {
                    let pipeline = filterPipeline
                    Task.detached(priority: .utility) {
                        await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: pipeline)
                    }
                }
        }
    }
}
