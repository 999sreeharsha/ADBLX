import Foundation

public enum WebExtensionArtifactFormat {
    /// Current format specification version
    public static let currentSchemaVersion: Int = 1
    
    /// Standard file names inside generation directories and WebExtension root
    public static let rulesFilename = "rules.json"
    public static let manifestFilename = "manifest.json"
    public static let currentPointerFilename = "current.json"
    public static let entitlementFilename = "entitlement.json"
    
    /// Safety boundaries
    public static let maxRulesSizeBytes: Int = 10 * 1024 * 1024 // 10 MB ceiling
    public static let maxSelectorLength: Int = 256
    public static let maxCombinatorDepth: Int = 4
    public static let maxSelectorsPerCategory: Int = 50
    
    /// Fixed binary domain allowlist ceiling
    public static let allowedDomains: [String] = [
        "m.youtube.com",
        "www.youtube.com"
    ]
}
