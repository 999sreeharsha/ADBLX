import Foundation
import ADBLXShared

public enum WebExtensionEntitlementPublisherError: Error, Equatable {
    case appGroupUnavailable
    case atomicWriteFailed(String)
}

public final class WebExtensionEntitlementPublisher {
    private let fileManager: FileManager
    
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }
    
    /// Atomically persists the authoritative StoreKit entitlement state to `WebExtension/entitlement.json`.
    ///
    /// - Parameters:
    ///   - isPremium: Authoritative StoreKit subscription status.
    ///   - baseAppGroupURL: Optional base App Group URL override (for testing).
    public func publish(
        isPremium: Bool,
        baseAppGroupURL: URL? = WebExtensionAppGroupPaths.appGroupContainerURL()
    ) throws {
        guard let baseURL = baseAppGroupURL else {
            throw WebExtensionEntitlementPublisherError.appGroupUnavailable
        }
        
        guard let rootDir = WebExtensionAppGroupPaths.webExtensionRootDirectory(base: baseURL),
              let entitlementURL = WebExtensionAppGroupPaths.entitlementFileURL(base: baseURL) else {
            throw WebExtensionEntitlementPublisherError.appGroupUnavailable
        }
        
        // Ensure root directory exists
        try fileManager.createDirectory(at: rootDir, withIntermediateDirectories: true)
        
        let state: WebExtensionPersistedEntitlementState = isPremium ? .premiumActive : .free
        let record = WebExtensionPersistedEntitlement(state: state, updatedAt: Date().timeIntervalSince1970)
        
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .sortedKeys
        let data = try jsonEncoder.encode(record)
        
        let tempURL = rootDir.appendingPathComponent("entitlement.tmp")
        try data.write(to: tempURL, options: .atomic)
        
        do {
            _ = try fileManager.replaceItemAt(entitlementURL, withItemAt: tempURL)
        } catch {
            if !fileManager.fileExists(atPath: entitlementURL.path) {
                try fileManager.moveItem(at: tempURL, to: entitlementURL)
            } else {
                throw WebExtensionEntitlementPublisherError.atomicWriteFailed(error.localizedDescription)
            }
        }
    }
}
