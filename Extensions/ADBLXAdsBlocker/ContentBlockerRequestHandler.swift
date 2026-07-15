import Foundation

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
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
                return appGroupURL
            }
        }
        return Bundle.main.url(forResource: "blockerList", withExtension: "json")
    }
}
