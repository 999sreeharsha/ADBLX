import Foundation
import OSLog

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    // Bundle.main inside an app extension resolves to the extension's own bundle ID
    // (com.ADBLX.ADBLX.AdsBlocker), not the app's — hardcode the shared app subsystem
    // so Console.app/log stream filtering by "com.ADBLX.ADBLX" catches both.
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "AppGroup")

    func beginRequest(with context: NSExtensionContext) {
        guard let url = Self.rulesURL() else {
            context.cancelRequest(withError: CocoaError(.fileNoSuchFile))
            return
        }

        guard let itemProvider = NSItemProvider(contentsOf: url) else {
            context.cancelRequest(withError: CocoaError(.fileReadCorruptFile))
            return
        }

        let item = NSExtensionItem()
        item.attachments = [itemProvider]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    private static func rulesURL() -> URL? {
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) {
            // Sprint 1: FilterStore/FilterPipeline write compiled output to Compiled/<Group>.json,
            // not the Sprint 0 Rules/Ads.json path.
            let appGroupURL = containerURL.appendingPathComponent("Compiled/Ads.json")
            if FileManager.default.fileExists(atPath: appGroupURL.path) {
                logger.info("Using App Group rules (\(ruleCount(at: appGroupURL)) rules)")
                return appGroupURL
            }
        }
        let bundledURL = Bundle.main.url(forResource: "blockerList", withExtension: "json")
        logger.info("Falling back to bundled rules (\(bundledURL.map { ruleCount(at: $0) } ?? 0) rules)")
        return bundledURL
    }

    private static func ruleCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return 0
        }
        return rules.count
    }
}
