import SafariServices
import ADBLXShared

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let processor = SafariWebExtensionBridgeProcessor()
    
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let messageDict = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        
        let responseDict = processor.processMessage(message: messageDict)
        
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: responseDict]
        
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
