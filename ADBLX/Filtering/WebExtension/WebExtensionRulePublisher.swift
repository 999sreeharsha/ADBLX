import Foundation
import ADBLXShared

public enum WebExtensionPublisherError: Error, Equatable {
    case appGroupUnavailable
    case stagingFailed(String)
    case validationFailed(WebExtensionValidationError)
    case serializationFailed(String)
    case atomicPointerUpdateFailed(String)
}

public final class WebExtensionRulePublisher {
    private let validator: WebExtensionSchemaValidator
    private let fileManager: FileManager
    
    public init(
        validator: WebExtensionSchemaValidator = WebExtensionSchemaValidator(),
        fileManager: FileManager = .default
    ) {
        self.validator = validator
        self.fileManager = fileManager
    }
    
    /// Validates inert rule data, stages an immutable generation directory, writes manifest & SHA-256 checksums,
    /// promotes the generation, and atomically points `current.json` to it.
    ///
    /// - Parameters:
    ///   - rulesData: Serialized `rules.json` candidate content.
    ///   - baseAppGroupURL: Optional base App Group URL override (for testing).
    /// - Returns: Published `WebExtensionGenerationManifest`.
    public func publish(
        rulesData: Data,
        baseAppGroupURL: URL? = WebExtensionAppGroupPaths.appGroupContainerURL()
    ) throws -> WebExtensionGenerationManifest {
        guard let baseURL = baseAppGroupURL else {
            throw WebExtensionPublisherError.appGroupUnavailable
        }
        
        guard let rootDir = WebExtensionAppGroupPaths.webExtensionRootDirectory(base: baseURL),
              let generationsDir = WebExtensionAppGroupPaths.generationsDirectory(base: baseURL),
              let stagingDir = WebExtensionAppGroupPaths.stagingDirectory(base: baseURL),
              let currentPointerURL = WebExtensionAppGroupPaths.currentPointerURL(base: baseURL) else {
            throw WebExtensionPublisherError.appGroupUnavailable
        }
        
        // 1. Strict Validation of candidate data before any file I/O
        do {
            try validator.validate(rulesData: rulesData)
        } catch let err as WebExtensionValidationError {
            throw WebExtensionPublisherError.validationFailed(err)
        } catch {
            throw WebExtensionPublisherError.serializationFailed(error.localizedDescription)
        }
        
        // Ensure root and generations directory exist
        try fileManager.createDirectory(at: generationsDir, withIntermediateDirectories: true)
        
        // 2. Determine next generation sequence number from current.json
        let currentGen = readActiveGenerationNumber(currentPointerURL: currentPointerURL)
        let nextGenNumber = currentGen + 1
        let nextGenName = String(format: "%06llu", nextGenNumber)
        let finalGenDir = generationsDir.appendingPathComponent(nextGenName, isDirectory: true)
        
        // 3. Prepare clean staging directory
        if fileManager.fileExists(atPath: stagingDir.path) {
            try fileManager.removeItem(at: stagingDir)
        }
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        
        // Cleanup staging on error
        defer {
            try? fileManager.removeItem(at: stagingDir)
        }
        
        // 4. Write rules.json and manifest.json to staging
        let rulesFileURL = stagingDir.appendingPathComponent(WebExtensionArtifactFormat.rulesFilename)
        let manifestFileURL = stagingDir.appendingPathComponent(WebExtensionArtifactFormat.manifestFilename)
        
        try rulesData.write(to: rulesFileURL, options: .atomic)
        
        let shaRules = WebExtensionGenerationManifest.computeSHA256(data: rulesData)
        let manifest = WebExtensionGenerationManifest(
            schemaVersion: WebExtensionArtifactFormat.currentSchemaVersion,
            generation: nextGenNumber,
            publishedAt: Date().timeIntervalSince1970,
            sha256Rules: shaRules,
            rulesSizeBytes: rulesData.count
        )
        
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .sortedKeys
        let manifestData = try jsonEncoder.encode(manifest)
        try manifestData.write(to: manifestFileURL, options: .atomic)
        
        // 5. Move staging directory to final immutable generation path
        if fileManager.fileExists(atPath: finalGenDir.path) {
            try fileManager.removeItem(at: finalGenDir)
        }
        try fileManager.moveItem(at: stagingDir, to: finalGenDir)
        
        // 6. Atomically publish current.json pointing to nextGenName
        let pointer = WebExtensionCurrentPointer(activeGeneration: nextGenName, publishedAt: manifest.publishedAt)
        let pointerData = try jsonEncoder.encode(pointer)
        
        let tempPointerURL = rootDir.appendingPathComponent("current.tmp")
        try pointerData.write(to: tempPointerURL, options: .atomic)
        
        do {
            _ = try fileManager.replaceItemAt(currentPointerURL, withItemAt: tempPointerURL)
        } catch {
            // Fallback to move if file did not exist previously
            if !fileManager.fileExists(atPath: currentPointerURL.path) {
                try fileManager.moveItem(at: tempPointerURL, to: currentPointerURL)
            } else {
                throw WebExtensionPublisherError.atomicPointerUpdateFailed(error.localizedDescription)
            }
        }
        
        // 7. Prune old generations (keep active and 1 previous generation; non-blocking)
        pruneOldGenerations(generationsDir: generationsDir, keepGenerations: [nextGenName, String(format: "%06llu", currentGen)])
        
        return manifest
    }
    
    private func readActiveGenerationNumber(currentPointerURL: URL) -> UInt64 {
        guard let data = try? Data(contentsOf: currentPointerURL),
              let pointer = try? JSONDecoder().decode(WebExtensionCurrentPointer.self, from: data),
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
}
