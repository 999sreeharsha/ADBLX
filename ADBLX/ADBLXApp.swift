import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    Task.detached(priority: .utility) {
                        ContentBlockerBootstrap.reloadIfNeeded()
                    }
                }
        }
    }
}
