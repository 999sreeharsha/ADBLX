import Foundation

public final class SafariWebExtensionBridgeProcessor {
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(fileManager: FileManager = .default, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileManager = fileManager
        self.now = now
    }
    
    /// Processes a native message dictionary received from JavaScript and produces the structured response dictionary.
    /// Operates in a strictly read-only manner against the App Group container.
    public func processMessage(
        message: [String: Any]?,
        baseAppGroupURL: URL? = WebExtensionAppGroupPaths.appGroupContainerURL()
    ) -> [String: Any] {
        guard let message = message,
              let typeString = message["type"] as? String,
              let messageType = WebExtensionBridgeMessageType(rawValue: typeString) else {
            return ["error": "Invalid or missing message type"]
        }
        
        switch messageType {
        case .checkVersion:
            return handleCheckVersion(baseAppGroupURL: baseAppGroupURL)
        case .fetchGeneration:
            guard let reqGen = message["generation"] as? Int, reqGen >= 0 else {
                return ["error": "Missing or invalid generation parameter"]
            }
            return handleFetchGeneration(generationNumber: UInt64(reqGen), baseAppGroupURL: baseAppGroupURL)
        }
    }
    
    private func handleCheckVersion(baseAppGroupURL: URL?) -> [String: Any] {
        guard let baseURL = baseAppGroupURL else {
            let response = WebExtensionCheckVersionResponse(
                generation: 0,
                generationStatus: .unavailable,
                entitlementState: .unavailable
            )
            return response.toDictionary()
        }
        
        // 1. Independent evaluation of active generation pointer
        var activeGenNumber: UInt64 = 0
        var genStatus: WebExtensionGenerationStatus = .unavailable
        
        if let pointerURL = WebExtensionAppGroupPaths.currentPointerURL(base: baseURL),
           let pointerData = try? Data(contentsOf: pointerURL),
           let pointer = try? JSONDecoder().decode(WebExtensionCurrentPointer.self, from: pointerData),
           let num = UInt64(pointer.activeGeneration) {
            activeGenNumber = num
            genStatus = .ok
        }
        
        // 2. Independent evaluation of entitlement state
        var entitlementState: WebExtensionEntitlementState = .unavailable
        var validUntil: TimeInterval?
        
        if let entitlementURL = WebExtensionAppGroupPaths.entitlementFileURL(base: baseURL),
           let entData = try? Data(contentsOf: entitlementURL),
           let entRecord = try? JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: entData) {
            validUntil = entRecord.validUntil
            switch entRecord.state {
            case .premiumActive:
                entitlementState = entRecord.isExpired(at: now()) ? .free : .premiumActive
            case .free:
                entitlementState = .free
            }
        }
        
        let response = WebExtensionCheckVersionResponse(
            generation: activeGenNumber,
            generationStatus: genStatus,
            entitlementState: entitlementState,
            checkedAt: now().timeIntervalSince1970,
            validUntil: validUntil
        )
        return response.toDictionary()
    }
    
    private func handleFetchGeneration(generationNumber: UInt64, baseAppGroupURL: URL?) -> [String: Any] {
        guard let baseURL = baseAppGroupURL else {
            let response = WebExtensionFetchGenerationResponse(
                generation: generationNumber,
                generationStatus: .unavailable
            )
            return response.toDictionary()
        }
        
        // Attempt generation read with bounded retry-once for transient filesystem swap
        var readAttempt = readGenerationPayload(generationNumber: generationNumber, baseAppGroupURL: baseURL)
        if readAttempt == nil {
            // Retry once
            readAttempt = readGenerationPayload(generationNumber: generationNumber, baseAppGroupURL: baseURL)
        }
        
        guard let (rulesJSON, checksum) = readAttempt else {
            let response = WebExtensionFetchGenerationResponse(
                generation: generationNumber,
                generationStatus: .unavailable
            )
            return response.toDictionary()
        }
        
        let response = WebExtensionFetchGenerationResponse(
            generation: generationNumber,
            generationStatus: .ok,
            rulesJSON: rulesJSON,
            checksum: checksum
        )
        return response.toDictionary()
    }
    
    private func readGenerationPayload(generationNumber: UInt64, baseAppGroupURL: URL) -> (rulesJSON: String, checksum: String)? {
        guard let genDir = WebExtensionAppGroupPaths.generationDirectory(generationNumber: generationNumber, base: baseAppGroupURL) else {
            return nil
        }
        
        let rulesURL = genDir.appendingPathComponent(WebExtensionArtifactFormat.rulesFilename)
        let manifestURL = genDir.appendingPathComponent(WebExtensionArtifactFormat.manifestFilename)
        
        guard let rulesData = try? Data(contentsOf: rulesURL),
              let rulesString = String(data: rulesData, encoding: .utf8),
              let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(WebExtensionGenerationManifest.self, from: manifestData) else {
            return nil
        }
        
        return (rulesString, manifest.sha256Rules)
    }
}
