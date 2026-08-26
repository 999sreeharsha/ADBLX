import Foundation
import ADBLXShared

public final class DNSAllowlistCompiler {
    public init() {}
    
    /// Compiles an array of user allowlist rule strings into a validated C2 binary allowlist overlay artifact.
    ///
    /// - Parameter rules: Array of user domain rules (e.g. `["apple.com", "developer.apple.com", "||example.org^"]`).
    /// - Returns: Serialized binary `Data` ready for App Group publication.
    public func compile(rules: [String]) throws -> Data {
        var reversedDomains: [String] = []
        
        for rule in rules {
            if let normalized = DNSDomainNormalizer.normalizeToReversedDomain(line: rule) {
                reversedDomains.append(normalized)
            }
        }
        
        return try DNSBinarySerializer.serialize(reversedDomains: reversedDomains)
    }
}
