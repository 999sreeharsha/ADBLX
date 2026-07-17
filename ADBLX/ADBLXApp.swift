import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterPipeline = AppCompositionRoot.makeFilterPipeline()

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    let pipeline = filterPipeline
                    Task.detached(priority: .utility) {
                        await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: pipeline)
                    }
                }
        }
    }
}
