import Foundation

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let url = Bundle.main.url(forResource: "blockerList", withExtension: "json") else {
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
}
