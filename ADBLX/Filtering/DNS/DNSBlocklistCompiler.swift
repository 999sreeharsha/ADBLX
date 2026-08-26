import Foundation
import ADBLXShared

public final class DNSBlocklistCompiler {
    public init() {}
    
    /// Compiles multiple raw blocklist string feeds into a single validated C2 binary blocklist artifact.
    ///
    /// - Parameter sourceContents: Array of raw filter list text strings (ABP, Hosts, or domain list format).
    /// - Returns: Serialized binary `Data` ready for App Group publication.
    public func compile(sourceContents: [String]) throws -> Data {
        var reversedDomains: [String] = []
        
        for content in sourceContents {
            content.enumerateLines { line, _ in
                if let normalized = DNSDomainNormalizer.normalizeToReversedDomain(line: line) {
                    reversedDomains.append(normalized)
                }
            }
        }
        
        return try DNSBinarySerializer.serialize(reversedDomains: reversedDomains)
    }
    
    /// Compiles blocklist from an array of local file URLs.
    public func compile(fileURLs: [URL]) throws -> Data {
        var sources: [String] = []
        for url in fileURLs {
            let text = try String(contentsOf: url, encoding: .utf8)
            sources.append(text)
        }
        return try compile(sourceContents: sources)
    }
}
