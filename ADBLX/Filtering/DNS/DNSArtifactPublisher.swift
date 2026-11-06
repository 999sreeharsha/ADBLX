import Foundation
import ADBLXShared

public enum DNSArtifactPublisherError: Error, Equatable {
    case appGroupUnavailable
    case stagingFailed(String)
    case validationFailed(DNSArtifactValidationError)
    case serializationFailed(String)
    case atomicPointerUpdateFailed(String)
    case coreDomainFalsePositive(domain: String)
}

public final class DNSArtifactPublisher {
    public static let protectedCoreDomains: [String] = [
        "google.com", "www.google.com",
        "apple.com", "www.apple.com", "icloud.com",
        "microsoft.com", "amazon.com",
        "whatsapp.com", "whatsapp.net",
        "facebook.com", "instagram.com",
        "youtube.com", "x.com", "twitter.com",
        "cloudflare.com"
    ]

    private let blocklistCompiler: DNSBlocklistCompiler
    private let allowlistCompiler: DNSAllowlistCompiler
    private let fileManager: FileManager
    
    public init(
        blocklistCompiler: DNSBlocklistCompiler = DNSBlocklistCompiler(),
        allowlistCompiler: DNSAllowlistCompiler = DNSAllowlistCompiler(),
        fileManager: FileManager = .default
    ) {
        self.blocklistCompiler = blocklistCompiler
        self.allowlistCompiler = allowlistCompiler
        self.fileManager = fileManager
    }
    
    /// Compiles blocklist and allowlist feeds, constructs an immutable generation directory,
    /// validates artifacts, and atomically activates the new generation via `current.json`.
    ///
    /// - Parameters:
    ///   - blocklistSources: Raw blocklist rule feeds.
    ///   - allowlistRules: Raw user allowlist rule strings.
    ///   - neverBlockRules: The never-block list (`DNSNeverBlockList`). Compiled into the allowlist
    ///     artifact, so the tunnel's allowlist-first check puts it ahead of every blocklist entry.
    ///   - baseAppGroupURL: Optional base App Group URL override (for testing).
    /// - Returns: Published `DNSGenerationManifest`.
    public func publish(
        blocklistSources: [String],
        allowlistRules: [String],
        neverBlockRules: [String] = [],
        baseAppGroupURL: URL? = DNSAppGroupPaths.appGroupContainerURL()
    ) throws -> DNSGenerationManifest {
        guard let baseURL = baseAppGroupURL else {
            throw DNSArtifactPublisherError.appGroupUnavailable
        }
        
        guard let dnsRoot = DNSAppGroupPaths.dnsRootDirectory(base: baseURL),
              let generationsDir = DNSAppGroupPaths.generationsDirectory(base: baseURL),
              let stagingDir = DNSAppGroupPaths.stagingDirectory(base: baseURL),
              let currentPointerURL = DNSAppGroupPaths.currentPointerURL(base: baseURL) else {
            throw DNSArtifactPublisherError.appGroupUnavailable
        }
        
        // Ensure root and generations directory exist
        try fileManager.createDirectory(at: generationsDir, withIntermediateDirectories: true)
        
        // 1. Determine next generation ID from current.json
        let currentGen = readActiveGenerationNumber(currentPointerURL: currentPointerURL)
        let nextGenNumber = currentGen + 1
        let nextGenName = String(format: "%06llu", nextGenNumber)
        let finalGenDir = generationsDir.appendingPathComponent(nextGenName, isDirectory: true)
        
        // 2. Prepare clean staging directory
        if fileManager.fileExists(atPath: stagingDir.path) {
            try fileManager.removeItem(at: stagingDir)
        }
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        
        // Cleanup staging on error
        defer {
            try? fileManager.removeItem(at: stagingDir)
        }
        
        // 3. Compile block.bin and allow.bin
        let blockData: Data
        let allowData: Data
        do {
            blockData = try blocklistCompiler.compile(sourceContents: blocklistSources)
            allowData = try allowlistCompiler.compile(rules: allowlistRules + neverBlockRules)
        } catch {
            throw DNSArtifactPublisherError.serializationFailed(error.localizedDescription)
        }
        
        // 4. Validate both binary artifacts from memory/disk
        let headerBlock: DNSArtifactHeader
        let headerAllow: DNSArtifactHeader
        do {
            headerBlock = try DNSArtifactValidator.validate(data: blockData)
            headerAllow = try DNSArtifactValidator.validate(data: allowData)
            let blockArtifact = MappedDNSArtifact(validatedData: blockData, header: headerBlock)
            try validateNoCoreDomainFalsePositives(blockArtifact: blockArtifact)
        } catch let err as DNSArtifactValidationError {
            throw DNSArtifactPublisherError.validationFailed(err)
        } catch let err as DNSArtifactPublisherError {
            throw err
        }
        
        let blockFileURL = stagingDir.appendingPathComponent(DNSArtifactFormat.blocklistFilename)
        let allowFileURL = stagingDir.appendingPathComponent(DNSArtifactFormat.allowlistFilename)
        let manifestFileURL = stagingDir.appendingPathComponent(DNSArtifactFormat.manifestFilename)
        
        try blockData.write(to: blockFileURL, options: .atomic)
        try allowData.write(to: allowFileURL, options: .atomic)
        
        // 5. Compute SHA-256 digests and serialize manifest.json
        let shaBlock = DNSGenerationManifest.computeSHA256(data: blockData)
        let shaAllow = DNSGenerationManifest.computeSHA256(data: allowData)
        
        let manifest = DNSGenerationManifest(
            generation: nextGenNumber,
            publishedAt: Date().timeIntervalSince1970,
            blocklistCount: Int(headerBlock.ruleCount),
            allowlistCount: Int(headerAllow.ruleCount),
            sha256Blocklist: shaBlock,
            sha256Allowlist: shaAllow
        )
        
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .sortedKeys
        let manifestData = try jsonEncoder.encode(manifest)
        try manifestData.write(to: manifestFileURL, options: .atomic)
        
        // 6. Move staging directory to final immutable generation path
        if fileManager.fileExists(atPath: finalGenDir.path) {
            try fileManager.removeItem(at: finalGenDir)
        }
        try fileManager.moveItem(at: stagingDir, to: finalGenDir)
        
        // 7. Atomically publish current.json pointing to nextGenName
        let pointer = DNSCurrentPointer(activeGeneration: nextGenName, publishedAt: manifest.publishedAt)
        let pointerData = try jsonEncoder.encode(pointer)
        
        let tempPointerURL = dnsRoot.appendingPathComponent("current.tmp")
        try pointerData.write(to: tempPointerURL, options: .atomic)
        
        do {
            _ = try fileManager.replaceItemAt(currentPointerURL, withItemAt: tempPointerURL)
        } catch {
            // Fallback to move if file did not exist previously
            if !fileManager.fileExists(atPath: currentPointerURL.path) {
                try fileManager.moveItem(at: tempPointerURL, to: currentPointerURL)
            } else {
                throw DNSArtifactPublisherError.atomicPointerUpdateFailed(error.localizedDescription)
            }
        }
        
        // 8. Prune old generations (keep active and 1 previous generation)
        pruneOldGenerations(generationsDir: generationsDir, keepGenerations: [nextGenName, String(format: "%06llu", currentGen)])
        
        return manifest
    }
    
    private func readActiveGenerationNumber(currentPointerURL: URL) -> UInt64 {
        guard let data = try? Data(contentsOf: currentPointerURL),
              let pointer = try? JSONDecoder().decode(DNSCurrentPointer.self, from: data),
              let num = UInt64(pointer.activeGeneration) else {
            return 0
        }
        return num
    }
    
    private func pruneOldGenerations(generationsDir: URL, keepGenerations: [String]) {
        guard let contents = try? fileManager.contentsOfDirectory(at: generationsDir, includingPropertiesForKeys: nil) else {
            return
        }
        
        let keepSet = Set(keepGenerations)
        for dirURL in contents where dirURL.hasDirectoryPath {
            let genName = dirURL.lastPathComponent
            if !keepSet.contains(genName) {
                try? fileManager.removeItem(at: dirURL)
            }
        }
    }
    
    private func validateNoCoreDomainFalsePositives(blockArtifact: MappedDNSArtifact) throws {
        for domain in Self.protectedCoreDomains {
            if blockArtifact.matchesDomain(domain: domain) {
                throw DNSArtifactPublisherError.coreDomainFalsePositive(domain: domain)
            }
        }
    }
}
