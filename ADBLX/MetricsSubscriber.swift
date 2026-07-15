import Foundation
import MetricKit
import OSLog

final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ADBLX.ADBLX",
        category: "MetricKit"
    )

    func didReceive(_ payloads: [MXMetricPayload]) {
        logger.info("Received \(payloads.count) MetricKit payload(s)")
    }
}
