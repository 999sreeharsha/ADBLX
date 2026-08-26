import Foundation

/// Explicit AST representation of ABP pattern matching styles.
public enum ABPPattern: Sendable, Equatable {
    case domainAnchor(String)        // ||domain.com^
    case urlPrefix(String)           // |http://domain.com
    case exactMatch(String)          // ||domain.com/path|
    case wildcard(String)            // /banner_*.gif
    case regularExpression(String)   // /regex/
}

public struct ParsedNetworkRule: Sendable, Equatable {
    public let pattern: ABPPattern
    public let isException: Bool
    public let rawModifiers: [String]
    
    public init(pattern: ABPPattern, isException: Bool, rawModifiers: [String]) {
        self.pattern = pattern
        self.isException = isException
        self.rawModifiers = rawModifiers
    }
}

public struct ParsedCosmeticRule: Sendable, Equatable {
    public let domains: [String]
    public let isException: Bool
    public let selector: String
    
    public init(domains: [String], isException: Bool, selector: String) {
        self.domains = domains
        self.isException = isException
        self.selector = selector
    }
}

public enum DeferredKind: Sendable, Equatable {
    case scriptlet
    case proceduralCSS
}

public struct ParsedDeferredRule: Sendable, Equatable {
    public let kind: DeferredKind
    public let rawText: String
    
    public init(kind: DeferredKind, rawText: String) {
        self.kind = kind
        self.rawText = rawText
    }
}

public struct ParsedInvalidRule: Sendable, Equatable {
    public let rawLine: String
    public let reason: String
    
    public init(rawLine: String, reason: String) {
        self.rawLine = rawLine
        self.reason = reason
    }
}

/// Abstract Syntax Tree (AST) representing a parsed ABP line.
public enum ParsedABPRule: Sendable, Equatable {
    case empty
    case comment(String)
    case network(ParsedNetworkRule)
    case cosmetic(ParsedCosmeticRule)
    case deferred(ParsedDeferredRule)
    case invalid(ParsedInvalidRule)
}
