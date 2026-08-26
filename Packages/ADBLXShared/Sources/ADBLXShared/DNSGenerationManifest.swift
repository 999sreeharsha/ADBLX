import Foundation
import CryptoKit

public struct DNSGenerationManifest: Codable, Equatable {
    public let generation: UInt64
    public let publishedAt: TimeInterval
    public let blocklistCount: Int
    public let allowlistCount: Int
    public let sha256Blocklist: String
    public let sha256Allowlist: String
    
    public init(
        generation: UInt64,
        publishedAt: TimeInterval = Date().timeIntervalSince1970,
        blocklistCount: Int,
        allowlistCount: Int,
        sha256Blocklist: String,
        sha256Allowlist: String
    ) {
        self.generation = generation
        self.publishedAt = publishedAt
        self.blocklistCount = blocklistCount
        self.allowlistCount = allowlistCount
        self.sha256Blocklist = sha256Blocklist
        self.sha256Allowlist = sha256Allowlist
    }
    
    public static func computeSHA256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    public static func readCurrentManifest(appGroupBaseDirectory: URL) throws -> DNSGenerationManifest {
        let pointer = try DNSCurrentPointer.readCurrent(appGroupBaseDirectory: appGroupBaseDirectory)
        guard let genDir = DNSAppGroupPaths.generationDirectory(generationName: pointer.activeGeneration, base: appGroupBaseDirectory) else {
            throw NSError(domain: "DNSGenerationManifest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid generation directory"])
        }
        let manifestURL = genDir.appendingPathComponent(DNSArtifactFormat.manifestFilename)
        let manifestData = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(DNSGenerationManifest.self, from: manifestData)
    }
}

public struct DNSCurrentPointer: Codable, Equatable {
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
    
    public static func readCurrent(appGroupBaseDirectory: URL) throws -> DNSCurrentPointer {
        guard let pointerURL = DNSAppGroupPaths.currentPointerURL(base: appGroupBaseDirectory) else {
            throw NSError(domain: "DNSCurrentPointer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid pointer URL"])
        }
        let pointerData = try Data(contentsOf: pointerURL)
        return try JSONDecoder().decode(DNSCurrentPointer.self, from: pointerData)
    }
}
