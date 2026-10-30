import Foundation

public enum SafariRuleGenerator: Sendable {
    /// What happened to a rule's `if-domain`/`unless-domain` lists. Safari cannot express
    /// entity domains (`site.*`) or paths, so those entries are removed; a rule is dropped
    /// whenever removing them would widen it.
    public enum DomainScopeOutcome: Sendable, Equatable {
        case kept
        /// Some unsupported domains were removed from a mixed list.
        case trimmed
        /// Every domain the rule named was unsupported.
        case droppedAllUnsupported
        /// Every included domain was unsupported, leaving only exclusions.
        case droppedUnlessOnly
        /// A hiding exception with no domains: Safari can only express it as cancelling
        /// every earlier rule on every page.
        case droppedGenericHidingException
    }

    /// Generates strongly-typed SafariContentBlockerRules from a ValidatedABPRule.
    public static func generate(from validated: ValidatedABPRule) -> [SafariContentBlockerRule] {
        generateWithScope(from: validated).rules
    }

    /// Like `generate(from:)`, also reporting how the rule's domain scope was handled.
    public static func generateWithScope(
        from validated: ValidatedABPRule
    ) -> (rules: [SafariContentBlockerRule], scope: DomainScopeOutcome) {
        switch validated {
        case .cosmetic(let cos):
            return generateCosmetic(cos)
        case .network(let net):
            return generateNetwork(net)
        }
    }

    private struct DomainScope {
        let ifDomains: [String]?
        let unlessDomains: [String]?
        let outcome: DomainScopeOutcome
    }

    private static func resolveScope(ifDomains: [String], unlessDomains: [String]) -> DomainScope {
        let keptIf = sanitizeDomains(ifDomains)
        let keptUnless = sanitizeDomains(unlessDomains)
        let named = ifDomains.count + unlessDomains.count
        let kept = keptIf.count + keptUnless.count

        let outcome: DomainScopeOutcome
        if named > 0 && kept == 0 {
            outcome = .droppedAllUnsupported
        } else if !ifDomains.isEmpty && keptIf.isEmpty {
            outcome = .droppedUnlessOnly
        } else {
            outcome = kept < named ? .trimmed : .kept
        }
        return DomainScope(
            ifDomains: keptIf.isEmpty ? nil : keptIf,
            unlessDomains: keptUnless.isEmpty ? nil : keptUnless,
            outcome: outcome
        )
    }

    private static func isDropped(_ outcome: DomainScopeOutcome) -> Bool {
        outcome != .kept && outcome != .trimmed
    }

    private static func generateCosmetic(
        _ cos: ValidatedCosmeticRule
    ) -> (rules: [SafariContentBlockerRule], scope: DomainScopeOutcome) {
        if !cos.isException && cos.selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ([], .kept)
        }

        let scope = resolveScope(ifDomains: cos.ifDomains, unlessDomains: cos.unlessDomains)
        if isDropped(scope.outcome) {
            return ([], scope.outcome)
        }
        // Safari has no selector-specific exception: `#@#.sel` with no domains would become
        // an ignore-previous-rules on every page.
        if cos.isException && scope.ifDomains == nil && scope.unlessDomains == nil {
            return ([], .droppedGenericHidingException)
        }

        let trigger = SafariContentBlockerRule.Trigger(
            urlFilter: ".*",
            ifDomain: scope.ifDomains,
            unlessDomain: scope.unlessDomains
        )
        
        let action: SafariContentBlockerRule.Action
        if cos.isException {
            action = SafariContentBlockerRule.Action(type: "ignore-previous-rules", selector: nil)
        } else {
            action = SafariContentBlockerRule.Action(type: "css-display-none", selector: cos.selector)
        }
        
        return ([SafariContentBlockerRule(trigger: trigger, action: action)], scope.outcome)
    }

    private static func generateNetwork(
        _ net: ValidatedNetworkRule
    ) -> (rules: [SafariContentBlockerRule], scope: DomainScopeOutcome) {
        var urlFilter = generateUrlFilter(from: net.pattern)
        if urlFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urlFilter = ".*"
        }

        // If the pattern was a raw regex with unsupported DFA features (like {n,m} or disjunctions), skip it
        if case .regularExpression(let rawRegex) = net.pattern {
            if isUnsupportedDFARegex(rawRegex) {
                return ([], .kept)
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
        
        let scope = resolveScope(ifDomains: net.ifDomains, unlessDomains: net.unlessDomains)
        if isDropped(scope.outcome) {
            return ([], scope.outcome)
        }
        let ifDomains = scope.ifDomains
        let unlessDomains = scope.unlessDomains

        // Fix A: reject pattern-less catch-all BLOCK rules. An ABP rule with an empty URL
        // pattern is scoped entirely by modifiers (e.g. `$ping,third-party`). WebKit's
        // declarative content blocker cannot reproduce that scoping faithfully, so such a
        // rule compiles to `url-filter: ".*"` + a `block` action and blocks the entire web
        // (this is what black-screened YouTube: all third-party XHR/fetch blocked). A
        // catch-all is only safe when domain-scoped or when it is an `ignore-previous-rules`
        // exception; an unscoped catch-all block is never intentional.
        if !net.isException && isCatchAllURLFilter(urlFilter) && ifDomains == nil {
            return ([], .kept)
        }

        let trigger = SafariContentBlockerRule.Trigger(
            urlFilter: urlFilter,
            ifDomain: ifDomains,
            unlessDomain: unlessDomains,
            resourceType: resourceTypeStrings,
            loadType: loadTypeStrings
        )

        let actionType = net.isException ? "ignore-previous-rules" : "block"
        let action = SafariContentBlockerRule.Action(type: actionType)

        return ([SafariContentBlockerRule(trigger: trigger, action: action)], scope.outcome)
    }

    /// True when a `url-filter` regex imposes no real URL constraint — it matches every URL.
    /// Covers the compiler's own empty-pattern fallback (`.*`) and the common hand-written
    /// equivalents that anchor nothing (`^.*`, `^https?://.*`, `.*$`, etc.).
    static func isCatchAllURLFilter(_ urlFilter: String) -> Bool {
        let trimmed = urlFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let catchAlls: Set<String> = [
            ".*", "^.*", ".*$", "^.*$",
            "^https?://.*", "^https?://.*$",
            "https?://.*", "^http.*",
        ]
        return catchAlls.contains(trimmed)
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
    
    private static func sanitizeDomains(_ domains: [String]) -> [String] {
        domains.compactMap { d -> String? in
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
