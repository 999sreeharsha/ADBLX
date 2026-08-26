import Foundation

/// Status of the rule generation read from App Group storage.
public enum WebExtensionGenerationStatus: String, Codable, Equatable, Sendable {
    case ok
    case unavailable
}

/// Dynamic entitlement state returned across the bridge to JavaScript.
/// Per ADR-0012: authorization fails closed (`free` or `unavailable` immediately halts Layer 3 premium).
public enum WebExtensionEntitlementState: String, Codable, Equatable, Sendable {
    case free
    case premiumActive
    case unavailable
}

/// Durable entitlement state persisted to `WebExtension/entitlement.json` by main app.
/// `unavailable` is a transient bridge error result, NEVER written to disk.
public enum WebExtensionPersistedEntitlementState: String, Codable, Equatable, Sendable {
    case free
    case premiumActive
}

/// Persistent record in `WebExtension/entitlement.json`.
public struct WebExtensionPersistedEntitlement: Codable, Equatable, Sendable {
    public let state: WebExtensionPersistedEntitlementState
    public let updatedAt: TimeInterval
    
    public init(state: WebExtensionPersistedEntitlementState, updatedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// Bridge message request types.
public enum WebExtensionBridgeMessageType: String, Codable, Equatable, Sendable {
    case checkVersion
    case fetchGeneration
}

/// Response payload for `checkVersion` native messaging request.
public struct WebExtensionCheckVersionResponse: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let generationStatus: WebExtensionGenerationStatus
    public let entitlementState: WebExtensionEntitlementState
    public let checkedAt: TimeInterval // Diagnostic/logging only
    
    public init(
        generation: UInt64,
        generationStatus: WebExtensionGenerationStatus,
        entitlementState: WebExtensionEntitlementState,
        checkedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.generation = generation
        self.generationStatus = generationStatus
        self.entitlementState = entitlementState
        self.checkedAt = checkedAt
    }
    
    public func toDictionary() -> [String: Any] {
        [
            "generation": Int(generation),
            "generationStatus": generationStatus.rawValue,
            "entitlementState": entitlementState.rawValue,
            "checkedAt": checkedAt
        ]
    }
}

/// Response payload for `fetchGeneration` native messaging request.
public struct WebExtensionFetchGenerationResponse: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let generationStatus: WebExtensionGenerationStatus
    public let rulesJSON: String?
    public let checksum: String?
    
    public init(
        generation: UInt64,
        generationStatus: WebExtensionGenerationStatus,
        rulesJSON: String? = nil,
        checksum: String? = nil
    ) {
        self.generation = generation
        self.generationStatus = generationStatus
        self.rulesJSON = rulesJSON
        self.checksum = checksum
    }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "generation": Int(generation),
            "generationStatus": generationStatus.rawValue
        ]
        if let rulesJSON = rulesJSON,
           let data = rulesJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            dict["rules"] = obj
        }
        if let checksum = checksum {
            dict["checksum"] = checksum
        }
        return dict
    }
}
