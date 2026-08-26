import Foundation

public enum WebExtensionAppGroupPaths {
    public static let appGroupIdentifier = "group.com.ADBLX.shared"
    
    public static func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }
    
    public static func webExtensionRootDirectory(base: URL? = appGroupContainerURL()) -> URL? {
        base?.appendingPathComponent("WebExtension", isDirectory: true)
    }
    
    public static func generationsDirectory(base: URL? = appGroupContainerURL()) -> URL? {
        webExtensionRootDirectory(base: base)?.appendingPathComponent("generations", isDirectory: true)
    }
    
    public static func stagingDirectory(base: URL? = appGroupContainerURL()) -> URL? {
        webExtensionRootDirectory(base: base)?.appendingPathComponent("staging", isDirectory: true)
    }
    
    public static func currentPointerURL(base: URL? = appGroupContainerURL()) -> URL? {
        webExtensionRootDirectory(base: base)?.appendingPathComponent(WebExtensionArtifactFormat.currentPointerFilename)
    }
    
    public static func entitlementFileURL(base: URL? = appGroupContainerURL()) -> URL? {
        webExtensionRootDirectory(base: base)?.appendingPathComponent(WebExtensionArtifactFormat.entitlementFilename)
    }
    
    public static func generationDirectory(generationNumber: UInt64, base: URL? = appGroupContainerURL()) -> URL? {
        let name = String(format: "%06llu", generationNumber)
        return generationsDirectory(base: base)?.appendingPathComponent(name, isDirectory: true)
    }
    
    public static func generationDirectory(generationName: String, base: URL? = appGroupContainerURL()) -> URL? {
        generationsDirectory(base: base)?.appendingPathComponent(generationName, isDirectory: true)
    }
}
