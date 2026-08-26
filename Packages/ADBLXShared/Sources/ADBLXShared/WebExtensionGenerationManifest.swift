import Foundation
import CryptoKit

public struct WebExtensionGenerationManifest: Codable, Equatable {
    public let schemaVersion: Int
    public let generation: UInt64
    public let publishedAt: TimeInterval
    public let sha256Rules: String
    public let rulesSizeBytes: Int
    
    public init(
        schemaVersion: Int = WebExtensionArtifactFormat.currentSchemaVersion,
        generation: UInt64,
        publishedAt: TimeInterval = Date().timeIntervalSince1970,
        sha256Rules: String,
        rulesSizeBytes: Int
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.publishedAt = publishedAt
        self.sha256Rules = sha256Rules
        self.rulesSizeBytes = rulesSizeBytes
    }
    
    public static func computeSHA256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    public static func readCurrentManifest(appGroupBaseDirectory: URL) throws -> WebExtensionGenerationManifest {
        let pointer = try WebExtensionCurrentPointer.readCurrent(appGroupBaseDirectory: appGroupBaseDirectory)
        guard let genDir = WebExtensionAppGroupPaths.generationDirectory(generationName: pointer.activeGeneration, base: appGroupBaseDirectory) else {
            throw NSError(domain: "WebExtensionGenerationManifest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid generation directory"])
        }
        let manifestURL = genDir.appendingPathComponent(WebExtensionArtifactFormat.manifestFilename)
        let manifestData = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(WebExtensionGenerationManifest.self, from: manifestData)
    }
}

public struct WebExtensionCurrentPointer: Codable, Equatable {
    public let activeGeneration: String
    public let publishedAt: TimeInterval
    
    public init(activeGeneration: String, publishedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.activeGeneration = activeGeneration
        self.publishedAt = publishedAt
    }
    
    public init(generationNumber: UInt64, publishedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.activeGeneration = String(format: "%06llu", generationNumber)
        self.publishedAt = publishedAt
    }
    
    public static func readCurrent(appGroupBaseDirectory: URL) throws -> WebExtensionCurrentPointer {
        guard let pointerURL = WebExtensionAppGroupPaths.currentPointerURL(base: appGroupBaseDirectory) else {
            throw NSError(domain: "WebExtensionCurrentPointer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid pointer URL"])
        }
        let pointerData = try Data(contentsOf: pointerURL)
        return try JSONDecoder().decode(WebExtensionCurrentPointer.self, from: pointerData)
    }
}
