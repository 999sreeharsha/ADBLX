import Foundation

public enum SafariDomainNormalizerError: Error, Equatable, Sendable {
    case emptyInput
    case ipAddressNotSupported
    case localhostNotSupported
    case labelLengthExceeded
    case domainLengthExceeded
    case invalidFormat(String)
}

public enum SafariDomainNormalizer: Sendable {
    /// Normalizes raw user input into a canonical lowercase forward domain string.
    public static func normalize(input: String) throws -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw SafariDomainNormalizerError.emptyInput
        }
        
        text = stripABPPrefixes(text)
        text = stripURLSchemes(text)
        
        let prePortTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isValidIPAddress(prePortTrimmed) || isValidIPAddress(prePortTrimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) {
            throw SafariDomainNormalizerError.ipAddressNotSupported
        }
        
        text = stripPathPortAndFragments(text)
        text = stripWildcardsAndDots(text)
        
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.isEmpty {
            throw SafariDomainNormalizerError.emptyInput
        }
        
        try validateBasicConstraints(cleaned)
        try validateDomainLabels(cleaned)
        
        return cleaned
    }
    
    private static func stripABPPrefixes(_ input: String) -> String {
        var text = input
        if text.hasPrefix("@@") {
            text = String(text.dropFirst(2))
        }
        if text.hasPrefix("||") {
            text = String(text.dropFirst(2))
        }
        if text.hasSuffix("^") {
            text = String(text.dropLast(1))
        }
        return text
    }
    
    private static func stripURLSchemes(_ input: String) -> String {
        let schemes = ["https://", "http://", "ws://", "wss://", "ftp://", "ftps://"]
        for scheme in schemes {
            if let range = input.range(of: scheme, options: .caseInsensitive) {
                return String(input[range.upperBound...])
            }
        }
        return input
    }
    
    private static func stripPathPortAndFragments(_ input: String) -> String {
        var text = input
        if let firstSlash = text.firstIndex(of: "/") {
            text = String(text[..<firstSlash])
        }
        if let queryIdx = text.firstIndex(of: "?") {
            text = String(text[..<queryIdx])
        }
        if let fragIdx = text.firstIndex(of: "#") {
            text = String(text[..<fragIdx])
        }
        if let colonIdx = text.firstIndex(of: ":") {
            text = String(text[..<colonIdx])
        }
        return text
    }
    
    private static func stripWildcardsAndDots(_ input: String) -> String {
        var text = input
        while text.hasPrefix("*.") {
            text = String(text.dropFirst(2))
        }
        while text.hasPrefix("*") {
            text = String(text.dropFirst(1))
        }
        while text.hasPrefix(".") {
            text = String(text.dropFirst(1))
        }
        while text.hasSuffix(".") {
            text = String(text.dropLast(1))
        }
        return text
    }
    
    private static func validateBasicConstraints(_ domain: String) throws {
        if domain.count > 253 {
            throw SafariDomainNormalizerError.domainLengthExceeded
        }
        if isValidIPAddress(domain) {
            throw SafariDomainNormalizerError.ipAddressNotSupported
        }
        if domain == "localhost" {
            throw SafariDomainNormalizerError.localhostNotSupported
        }
    }
    
    private static func validateDomainLabels(_ domain: String) throws {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            throw SafariDomainNormalizerError.invalidFormat("Single label domains are not supported")
        }
        
        for labelSubstring in labels {
            let label = String(labelSubstring)
            if label.isEmpty {
                throw SafariDomainNormalizerError.invalidFormat("Empty label found in domain")
            }
            if label.count > 63 {
                throw SafariDomainNormalizerError.labelLengthExceeded
            }
            if label.hasPrefix("-") || label.hasSuffix("-") {
                throw SafariDomainNormalizerError.invalidFormat("Label cannot start or end with a hyphen")
            }
            try validateLabelCharacters(label)
        }
    }
    
    private static func validateLabelCharacters(_ label: String) throws {
        for char in label.utf8 {
            let isAlpha = (char >= 97 && char <= 122) // a-z
            let isNum = (char >= 48 && char <= 57)   // 0-9
            let isHyphen = (char == 45)              // -
            if !isAlpha && !isNum && !isHyphen {
                throw SafariDomainNormalizerError.invalidFormat("Invalid character in domain label")
            }
        }
    }
    
    private static func isValidIPAddress(_ str: String) -> Bool {
        var sin = sockaddr_in()
        if str.withCString({ inet_pton(AF_INET, $0, &sin.sin_addr) }) == 1 {
            return true
        }
        var sin6 = sockaddr_in6()
        if str.withCString({ inet_pton(AF_INET6, $0, &sin6.sin6_addr) }) == 1 {
            return true
        }
        return false
    }
}
