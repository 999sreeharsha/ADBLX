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
            let appGroupURL = containerURL.appendingPathComponent("Rules/Ads.json")
            if FileManager.default.fileExists(atPath: appGroupURL.path) {
                logger.info("Using App Group rules at \(appGroupURL.path, privacy: .public)")
                return appGroupURL
            }
        }
        logger.info("App Group rules unavailable, falling back to bundled blockerList.json")
        return Bundle.main.url(forResource: "blockerList", withExtension: "json")
    }
}
