import Foundation
import ADBLXShared

public final class DNSLookupSnapshot {
    public let generation: UInt64
    public let blocklist: MappedDNSArtifact
    public let allowlist: MappedDNSArtifact
    public let manifest: DNSGenerationManifest?
    
    public init(
        generation: UInt64,
        blocklist: MappedDNSArtifact,
        allowlist: MappedDNSArtifact,
        manifest: DNSGenerationManifest? = nil
    ) {
        self.generation = generation
        self.blocklist = blocklist
        self.allowlist = allowlist
        self.manifest = manifest
    }
    
    /// Creates an empty fallback snapshot (0 rules in blocklist, 0 in allowlist)
    public static func makeEmptySnapshot() -> DNSLookupSnapshot {
        let emptyHeader = DNSArtifactHeader(ruleCount: 0, stringBlobSize: 0, payloadCRC32: 0)
        let emptyBlock = MappedDNSArtifact(validatedData: emptyHeader.serialize(), header: emptyHeader)
        let emptyAllow = MappedDNSArtifact(validatedData: emptyHeader.serialize(), header: emptyHeader)
        return DNSLookupSnapshot(generation: 0, blocklist: emptyBlock, allowlist: emptyAllow, manifest: nil)
    }
}
