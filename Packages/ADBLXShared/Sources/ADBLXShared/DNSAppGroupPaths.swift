import Foundation

public enum DNSAppGroupPaths {
    public static let appGroupIdentifier = "group.com.ADBLX.shared"
    
    public static func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }
    
    public static func dnsRootDirectory(base: URL? = appGroupContainerURL()) -> URL? {
        base?.appendingPathComponent("DNS", isDirectory: true)
    }
    
    public static func generationsDirectory(base: URL? = appGroupContainerURL()) -> URL? {
        dnsRootDirectory(base: base)?.appendingPathComponent("generations", isDirectory: true)
    }
    
    public static func stagingDirectory(base: URL? = appGroupContainerURL()) -> URL? {
        dnsRootDirectory(base: base)?.appendingPathComponent("staging", isDirectory: true)
    }
    
    public static func currentPointerURL(base: URL? = appGroupContainerURL()) -> URL? {
        dnsRootDirectory(base: base)?.appendingPathComponent(DNSArtifactFormat.currentPointerFilename)
    }
    
    public static func generationDirectory(generationNumber: UInt64, base: URL? = appGroupContainerURL()) -> URL? {
        let name = String(format: "%06llu", generationNumber)
        return generationsDirectory(base: base)?.appendingPathComponent(name, isDirectory: true)
    }
    
    public static func generationDirectory(generationName: String, base: URL? = appGroupContainerURL()) -> URL? {
        generationsDirectory(base: base)?.appendingPathComponent(generationName, isDirectory: true)
    }
}
