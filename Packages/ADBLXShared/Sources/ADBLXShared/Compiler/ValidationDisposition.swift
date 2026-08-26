import Foundation

public enum SafariLoadType: String, Sendable, Equatable, Codable {
    case firstParty = "first-party"
    case thirdParty = "third-party"
}

public struct ValidatedNetworkRule: Sendable, Equatable {
    public let pattern: ABPPattern
    public let isException: Bool
    public let loadType: SafariLoadType?
    public let resourceTypes: Set<SafariResourceType>
    public let ifDomains: [String]
    public let unlessDomains: [String]
    
    public init(
        pattern: ABPPattern,
        isException: Bool,
        loadType: SafariLoadType? = nil,
        resourceTypes: Set<SafariResourceType> = [],
        ifDomains: [String] = [],
        unlessDomains: [String] = []
    ) {
        self.pattern = pattern
        self.isException = isException
        self.loadType = loadType
        self.resourceTypes = resourceTypes
        self.ifDomains = ifDomains
        self.unlessDomains = unlessDomains
    }
}

public struct ValidatedCosmeticRule: Sendable, Equatable {
    public let ifDomains: [String]
    public let unlessDomains: [String]
    public let isException: Bool
    public let selector: String
    
    public init(
        ifDomains: [String] = [],
        unlessDomains: [String] = [],
        isException: Bool,
        selector: String
    ) {
        self.ifDomains = ifDomains
        self.unlessDomains = unlessDomains
        self.isException = isException
        self.selector = selector
    }
}

public enum ValidatedABPRule: Sendable, Equatable {
    case network(ValidatedNetworkRule)
    case cosmetic(ValidatedCosmeticRule)
}

public enum ValidationDisposition: Sendable, Equatable {
    case supported(ValidatedABPRule)
    case unsupportedSemantic(reason: String, modifier: String)
    case deferredToWebExtension(reason: String)
    case invalid(reason: String)
    case ignored(reason: String)
}
