import Foundation
import OSLog

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    // Bundle.main inside an app extension resolves to the extension's own bundle ID
    // (com.ADBLX.ADBLX.AnnoyancesBlocker), not the app's — hardcode the shared app
    // subsystem so Console.app/log stream filtering by "com.ADBLX.ADBLX" catches both.
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
            let appGroupURL = containerURL.appendingPathComponent("Compiled/Annoyances.json")
            if FileManager.default.fileExists(atPath: appGroupURL.path) {
                logger.info("Using App Group rules (\(CompiledRuleCount.label(forRulesAt: appGroupURL), privacy: .public) rules)")
                return appGroupURL
            }
        }
        logger.info("Falling back to bundled rules")
        return Bundle.main.url(forResource: "blockerList", withExtension: "json")
    }
}
