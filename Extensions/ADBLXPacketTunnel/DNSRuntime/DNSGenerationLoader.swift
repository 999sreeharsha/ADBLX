import Foundation
import os
import ADBLXShared

public enum DNSGenerationLoaderError: Error, Equatable {
    case appGroupUnavailable
    case currentPointerMissing
    case currentPointerCorrupt(String)
    case generationDirectoryMissing(String)
    case manifestMissing(String)
    case manifestCorrupt(String)
    case artifactValidationFailed(String)
    case sha256Mismatch(file: String, expected: String, actual: String)
    case ruleCountMismatch(file: String, expected: Int, actual: UInt32)
}

public final class DNSGenerationLoader {
    private let logger = Logger(subsystem: "com.ADBLX.ADBLX.ADBLXPacketTunnel", category: "DNSGenerationLoader")
    private let fileManager: FileManager
    private var lastKnownPointerModificationDate: Date?
    
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }
    
    private func pointerHasChanged(currentPointerURL: URL) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: currentPointerURL.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return true
        }
        if modDate == lastKnownPointerModificationDate {
            return false
        }
        lastKnownPointerModificationDate = modDate
        return true
    }
    
    /// Loads and comprehensively validates the active generation specified by `current.json`.
    ///
    /// - Parameter baseAppGroupURL: App Group container URL.
    /// - Returns: Complete, validated, immutable `DNSLookupSnapshot`.
    public func loadActiveGeneration(
        baseAppGroupURL: URL? = DNSAppGroupPaths.appGroupContainerURL()
    ) throws -> DNSLookupSnapshot {
        guard let baseURL = baseAppGroupURL else {
            throw DNSGenerationLoaderError.appGroupUnavailable
        }
        
        guard let currentPointerURL = DNSAppGroupPaths.currentPointerURL(base: baseURL) else {
            throw DNSGenerationLoaderError.appGroupUnavailable
        }
        
        // 1. Read current.json
        guard fileManager.fileExists(atPath: currentPointerURL.path) else {
            throw DNSGenerationLoaderError.currentPointerMissing
        }
        
        if let attrs = try? fileManager.attributesOfItem(atPath: currentPointerURL.path),
           let modDate = attrs[.modificationDate] as? Date {
            self.lastKnownPointerModificationDate = modDate
        }
        
        let pointerData: Data
        do {
            pointerData = try Data(contentsOf: currentPointerURL)
        } catch {
            throw DNSGenerationLoaderError.currentPointerCorrupt(error.localizedDescription)
        }
        
        let pointer: DNSCurrentPointer
        do {
            pointer = try JSONDecoder().decode(DNSCurrentPointer.self, from: pointerData)
        } catch {
            throw DNSGenerationLoaderError.currentPointerCorrupt(error.localizedDescription)
        }
        
        guard let genDir = DNSAppGroupPaths.generationDirectory(generationName: pointer.activeGeneration, base: baseURL),
              fileManager.fileExists(atPath: genDir.path) else {
            throw DNSGenerationLoaderError.generationDirectoryMissing(pointer.activeGeneration)
        }
        
        // 2. Read manifest.json
        let manifestURL = genDir.appendingPathComponent(DNSArtifactFormat.manifestFilename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw DNSGenerationLoaderError.manifestMissing(manifestURL.path)
        }
        
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw DNSGenerationLoaderError.manifestCorrupt(error.localizedDescription)
        }
        
        let manifest: DNSGenerationManifest
        do {
            manifest = try JSONDecoder().decode(DNSGenerationManifest.self, from: manifestData)
        } catch {
            throw DNSGenerationLoaderError.manifestCorrupt(error.localizedDescription)
        }
        
        // 3. Map block.bin and allow.bin
        let blockURL = genDir.appendingPathComponent(DNSArtifactFormat.blocklistFilename)
        let allowURL = genDir.appendingPathComponent(DNSArtifactFormat.allowlistFilename)
        
        let blockArtifact: MappedDNSArtifact
        let allowArtifact: MappedDNSArtifact
        
        do {
            blockArtifact = try MappedDNSArtifact(fileURL: blockURL)
            allowArtifact = try MappedDNSArtifact(fileURL: allowURL)
        } catch {
            throw DNSGenerationLoaderError.artifactValidationFailed(error.localizedDescription)
        }
        
        // 4. Verify SHA-256 digests against manifest
        let actualBlockSHA = DNSGenerationManifest.computeSHA256(data: blockArtifact.data)
        guard actualBlockSHA == manifest.sha256Blocklist else {
            throw DNSGenerationLoaderError.sha256Mismatch(file: "block.bin", expected: manifest.sha256Blocklist, actual: actualBlockSHA)
        }
        
        let actualAllowSHA = DNSGenerationManifest.computeSHA256(data: allowArtifact.data)
        guard actualAllowSHA == manifest.sha256Allowlist else {
            throw DNSGenerationLoaderError.sha256Mismatch(file: "allow.bin", expected: manifest.sha256Allowlist, actual: actualAllowSHA)
        }
        
        // 5. Verify rule counts against manifest
        guard Int(blockArtifact.ruleCount) == manifest.blocklistCount else {
            throw DNSGenerationLoaderError.ruleCountMismatch(file: "block.bin", expected: manifest.blocklistCount, actual: blockArtifact.ruleCount)
        }
        
        guard Int(allowArtifact.ruleCount) == manifest.allowlistCount else {
            throw DNSGenerationLoaderError.ruleCountMismatch(file: "allow.bin", expected: manifest.allowlistCount, actual: allowArtifact.ruleCount)
        }
        
        logger.notice("Successfully loaded and validated DNS generation \(manifest.generation, privacy: .public) (Blocklist: \(manifest.blocklistCount, privacy: .public) rules, Allowlist: \(manifest.allowlistCount, privacy: .public) rules)")
        
        return DNSLookupSnapshot(
            generation: manifest.generation,
            blocklist: blockArtifact,
            allowlist: allowArtifact,
            manifest: manifest
        )
    }
    
    /// Checks for a new generation in App Group storage and swaps it into the engine with Last-Known-Good fallback.
    ///
    /// - Parameters:
    ///   - engine: Target `DNSLookupEngine` to update.
    ///   - baseAppGroupURL: Base App Group URL.
    /// - Returns: `true` if a new generation was successfully loaded and swapped; `false` otherwise.
    @discardableResult
    public func reloadIfUpdated(
        engine: DNSLookupEngine,
        baseAppGroupURL: URL? = DNSAppGroupPaths.appGroupContainerURL()
    ) -> Bool {
        guard let baseURL = baseAppGroupURL,
              let currentPointerURL = DNSAppGroupPaths.currentPointerURL(base: baseURL) else {
            return false
        }
        
        guard pointerHasChanged(currentPointerURL: currentPointerURL) else {
            return false
        }
        
        do {
            let candidateSnapshot = try loadActiveGeneration(baseAppGroupURL: baseAppGroupURL)
            if candidateSnapshot.generation != engine.activeGeneration {
                engine.swapSnapshot(candidateSnapshot)
                logger.notice("Swapped active DNS lookup engine to generation \(candidateSnapshot.generation, privacy: .public)")
                return true
            }
            return false
        } catch {
            logger.error("Failed to load candidate DNS generation: \(error.localizedDescription, privacy: .public). Retaining Last-Known-Good generation \(engine.activeGeneration, privacy: .public)")
            return false
        }
    }
}
