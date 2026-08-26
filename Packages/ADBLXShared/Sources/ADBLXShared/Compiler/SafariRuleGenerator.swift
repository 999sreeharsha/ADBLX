import Foundation

public enum SafariRuleGenerator: Sendable {
    /// Generates strongly-typed SafariContentBlockerRules from a ValidatedABPRule.
    public static func generate(from validated: ValidatedABPRule) -> [SafariContentBlockerRule] {
        switch validated {
        case .cosmetic(let cos):
            return generateCosmetic(cos)
        case .network(let net):
            return generateNetwork(net)
        }
    }
    
    private static func generateCosmetic(_ cos: ValidatedCosmeticRule) -> [SafariContentBlockerRule] {
        if !cos.isException && cos.selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        
        let ifDomains = sanitizeDomains(cos.ifDomains)
        let unlessDomains = sanitizeDomains(cos.unlessDomains)
        
        let trigger = SafariContentBlockerRule.Trigger(
            urlFilter: ".*",
            ifDomain: ifDomains,
            unlessDomain: unlessDomains
        )
        
        let action: SafariContentBlockerRule.Action
        if cos.isException {
            action = SafariContentBlockerRule.Action(type: "ignore-previous-rules", selector: nil)
        } else {
            action = SafariContentBlockerRule.Action(type: "css-display-none", selector: cos.selector)
        }
        
        return [SafariContentBlockerRule(trigger: trigger, action: action)]
    }
    
    private static func generateNetwork(_ net: ValidatedNetworkRule) -> [SafariContentBlockerRule] {
        var urlFilter = generateUrlFilter(from: net.pattern)
        if urlFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urlFilter = ".*"
        }
        
        // If the pattern was a raw regex with unsupported DFA features (like {n,m} or disjunctions), skip it
        if case .regularExpression(let rawRegex) = net.pattern {
            if isUnsupportedDFARegex(rawRegex) {
                return []
            }
        }
        
        let loadTypeStrings: [String]?
        if let lt = net.loadType {
            loadTypeStrings = [lt.rawValue]
        } else {
            loadTypeStrings = nil
        }
        
        let resourceTypeStrings: [String]?
        if !net.resourceTypes.isEmpty {
            resourceTypeStrings = net.resourceTypes.map(\.rawValue).sorted()
        } else {
            resourceTypeStrings = nil
        }
        
        let ifDomains = sanitizeDomains(net.ifDomains)
        let unlessDomains = sanitizeDomains(net.unlessDomains)
        
        let trigger = SafariContentBlockerRule.Trigger(
            urlFilter: urlFilter,
            ifDomain: ifDomains,
            unlessDomain: unlessDomains,
            resourceType: resourceTypeStrings,
            loadType: loadTypeStrings
        )
        
        let actionType = net.isException ? "ignore-previous-rules" : "block"
        let action = SafariContentBlockerRule.Action(type: actionType)
        
        return [SafariContentBlockerRule(trigger: trigger, action: action)]
    }
    
    private static func isUnsupportedDFARegex(_ regex: String) -> Bool {
        // WebKit Content Blocker DFA engine does not support arbitrary repetitions {n,m} or disjunctions |
        if regex.contains("{") && regex.contains("}") {
            return true
        }
        if regex.contains("|") {
            return true
        }
        return false
    }
    
    private static func sanitizeDomains(_ domains: [String]) -> [String]? {
        let sanitized = domains.compactMap { d -> String? in
            var cleaned = d.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hasLeadingWildcard = cleaned.hasPrefix("*")
            if hasLeadingWildcard {
                cleaned.removeFirst()
            }
            // Domain must be ASCII letters, digits, '.', '-'
            guard cleaned.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
                  !cleaned.isEmpty else {
                return nil
            }
            return "*\(cleaned)"
        }
        return sanitized.isEmpty ? nil : sanitized
    }
    
    public static func generateUrlFilter(from pattern: ABPPattern) -> String {
        switch pattern {
        case .domainAnchor(let domain):
            let escapedDomain = escapeRegex(domain.lowercased())
            return "^https?://([a-zA-Z0-9-]+\\.)*\(escapedDomain)"
        case .urlPrefix(let prefix):
            let escaped = escapeRegex(prefix)
            return "^" + escaped
        case .exactMatch(let exact):
            let escaped = escapeRegex(exact)
            return "^https?://([a-zA-Z0-9-]+\\.)*\(escaped)$"
        case .wildcard(let wildcard):
            if wildcard == ".*" || wildcard == "*" {
                return ".*"
            }
            return convertWildcardToRegex(wildcard)
        case .regularExpression(let regex):
            return regex
        }
    }
    
    private static func escapeRegex(_ string: String) -> String {
        return NSRegularExpression.escapedPattern(for: string)
            .replacingOccurrences(of: "\\/", with: "/")
    }
    
    private static func convertWildcardToRegex(_ pattern: String) -> String {
        var regex = ""
        var i = pattern.startIndex
        
        while i < pattern.endIndex {
            let char = pattern[i]
            if char == "*" {
                regex.append(".*")
            } else if char == "^" {
                regex.append("[^a-zA-Z0-9_.~%-]")
            } else {
                let s = String(char)
                let escaped = escapeRegex(s)
                regex.append(escaped)
            }
            i = pattern.index(after: i)
        }
        return regex
    }
}
