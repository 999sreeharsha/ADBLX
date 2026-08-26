import Foundation
import ADBLXShared

public enum WebExtensionValidationError: Error, Equatable {
    case payloadTooLarge(sizeBytes: Int, maxAllowed: Int)
    case invalidJSON(String)
    case unsupportedSchemaVersion(Int)
    case selectorCountExceeded(category: String, count: Int, maxAllowed: Int)
    case selectorTooLong(selector: String, length: Int, maxAllowed: Int)
    case selectorCombinatorDepthExceeded(selector: String, depth: Int, maxAllowed: Int)
    case prohibitedSelectorConstruct(selector: String, construct: String)
    case outOfRangeParameter(parameter: String, value: Double, minAllowed: Double, maxAllowed: Double)
    case invalidDomainInDisableMask(domain: String)
}

public struct WebExtensionSchemaValidator {
    public init() {}
    
    /// Validates raw `rules.json` payload against strict Task 5 schema and bounds.
    /// Rejects out-of-range or malformed entries; NEVER silently clamps.
    public func validate(rulesData: Data) throws {
        // 1. Size budget validation
        if rulesData.count > WebExtensionArtifactFormat.maxRulesSizeBytes {
            throw WebExtensionValidationError.payloadTooLarge(
                sizeBytes: rulesData.count,
                maxAllowed: WebExtensionArtifactFormat.maxRulesSizeBytes
            )
        }
        
        // 2. JSON Structure validation
        guard let jsonObject = try? JSONSerialization.jsonObject(with: rulesData) as? [String: Any] else {
            throw WebExtensionValidationError.invalidJSON("Root must be a valid JSON object")
        }
        
        guard let schemaVersion = jsonObject["schemaVersion"] as? Int else {
            throw WebExtensionValidationError.invalidJSON("Missing schemaVersion")
        }
        
        guard schemaVersion == WebExtensionArtifactFormat.currentSchemaVersion else {
            throw WebExtensionValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        
        // 3. YouTube configuration validation
        if let youtube = jsonObject["youtube"] as? [String: Any] {
            try validateYouTubeConfiguration(youtube)
        }
    }
    
    private func validateYouTubeConfiguration(_ youtube: [String: Any]) throws {
        // Disable mask validation
        if let disableMask = youtube["disableMask"] as? [String: Any] {
            if let disabledDomains = disableMask["disabledDomains"] as? [String] {
                let allowedSet = Set(WebExtensionArtifactFormat.allowedDomains)
                for domain in disabledDomains {
                    if !allowedSet.contains(domain) {
                        throw WebExtensionValidationError.invalidDomainInDisableMask(domain: domain)
                    }
                }
            }
        }
        
        // Selectors validation
        if let selectors = youtube["selectors"] as? [String: Any] {
            let categories = [
                "playerContainers",
                "adStateClasses",
                "skipButtons",
                "adBadges",
                "cosmeticHideTargets"
            ]
            
            for category in categories {
                if let selectorList = selectors[category] as? [String] {
                    if selectorList.count > WebExtensionArtifactFormat.maxSelectorsPerCategory {
                        throw WebExtensionValidationError.selectorCountExceeded(
                            category: category,
                            count: selectorList.count,
                            maxAllowed: WebExtensionArtifactFormat.maxSelectorsPerCategory
                        )
                    }
                    for selector in selectorList {
                        try validateSelector(selector)
                    }
                }
            }
        }
        
        // Parameters validation (Rejection on out-of-range; NO clamping)
        if let parameters = youtube["parameters"] as? [String: Any] {
            if let maxRate = parameters["maxAccelerationRate"] as? Double {
                if maxRate < 1.0 || maxRate > 16.0 {
                    throw WebExtensionValidationError.outOfRangeParameter(
                        parameter: "maxAccelerationRate",
                        value: maxRate,
                        minAllowed: 1.0,
                        maxAllowed: 16.0
                    )
                }
            }
            
            if let confirmWindow = parameters["candidateConfirmationWindowMs"] as? Double {
                if confirmWindow < 10.0 || confirmWindow > 1000.0 {
                    throw WebExtensionValidationError.outOfRangeParameter(
                        parameter: "candidateConfirmationWindowMs",
                        value: confirmWindow,
                        minAllowed: 10.0,
                        maxAllowed: 1000.0
                    )
                }
            }
            
            if let recoveryWindow = parameters["safeRecoveryStabilityWindowMs"] as? Double {
                if recoveryWindow < 50.0 || recoveryWindow > 5000.0 {
                    throw WebExtensionValidationError.outOfRangeParameter(
                        parameter: "safeRecoveryStabilityWindowMs",
                        value: recoveryWindow,
                        minAllowed: 50.0,
                        maxAllowed: 5000.0
                    )
                }
            }
        }
    }
    
    private func validateSelector(_ selector: String) throws {
        if selector.count > WebExtensionArtifactFormat.maxSelectorLength {
            throw WebExtensionValidationError.selectorTooLong(
                selector: selector,
                length: selector.count,
                maxAllowed: WebExtensionArtifactFormat.maxSelectorLength
            )
        }
        
        let prohibitedSubstrings = ["javascript:", "expression(", "-moz-binding", "<script", "eval("]
        let lower = selector.lowercased()
        for prohibited in prohibitedSubstrings {
            if lower.contains(prohibited) {
                throw WebExtensionValidationError.prohibitedSelectorConstruct(
                    selector: selector,
                    construct: prohibited
                )
            }
        }
        
        // Combinator depth check
        let combinators = CharacterSet(charactersIn: " >+~")
        let components = selector.components(separatedBy: combinators).filter { !$0.isEmpty }
        let depth = max(0, components.count - 1)
        if depth > WebExtensionArtifactFormat.maxCombinatorDepth {
            throw WebExtensionValidationError.selectorCombinatorDepthExceeded(
                selector: selector,
                depth: depth,
                maxAllowed: WebExtensionArtifactFormat.maxCombinatorDepth
            )
        }
    }
}
