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
    /// Epoch seconds after which `premiumActive` must be treated as `free` by readers that
    /// cannot rely on the app running (web extension, packet tunnel). `nil` = no expiry
    /// (lifetime, or a legacy record written before this field existed).
    public let validUntil: TimeInterval?

    public init(
        state: WebExtensionPersistedEntitlementState,
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        validUntil: TimeInterval? = nil
    ) {
        self.state = state
        self.updatedAt = updatedAt
        self.validUntil = validUntil
    }

    /// Single date comparison — safe to call from size-constrained extensions.
    public func isExpired(at date: Date) -> Bool {
        guard let validUntil else { return false }
        return date.timeIntervalSince1970 >= validUntil
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
    /// Epoch seconds after which the extension must itself treat `premiumActive` as `free`.
    public let validUntil: TimeInterval?

    public init(
        generation: UInt64,
        generationStatus: WebExtensionGenerationStatus,
        entitlementState: WebExtensionEntitlementState,
        checkedAt: TimeInterval = Date().timeIntervalSince1970,
        validUntil: TimeInterval? = nil
    ) {
        self.validUntil = validUntil
        self.generation = generation
        self.generationStatus = generationStatus
        self.entitlementState = entitlementState
        self.checkedAt = checkedAt
    }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "generation": Int(generation),
            "generationStatus": generationStatus.rawValue,
            "entitlementState": entitlementState.rawValue,
            "checkedAt": checkedAt
        ]
        if let validUntil {
            dict["validUntilMs"] = Int(validUntil * 1000)
        }
        return dict
    }
}

/// Response payload for `fetchGeneration` native messaging request. No checksum: the rules and
/// their checksum sit in the same App Group with the same writer, so checking one against the
/// other protected nothing (SEC-18).
public struct WebExtensionFetchGenerationResponse: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let generationStatus: WebExtensionGenerationStatus
    public let rulesJSON: String?
    
    public init(
        generation: UInt64,
        generationStatus: WebExtensionGenerationStatus,
        rulesJSON: String? = nil
    ) {
        self.generation = generation
        self.generationStatus = generationStatus
        self.rulesJSON = rulesJSON
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
        return dict
    }
}
