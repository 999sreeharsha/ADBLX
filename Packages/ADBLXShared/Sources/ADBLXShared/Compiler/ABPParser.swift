import Foundation

public enum ABPParser: Sendable {
    /// Transforms a raw filter line or LexedABPLine into a strongly-typed ParsedABPRule AST.
    public static func parse(line: String) -> ParsedABPRule {
        let lexed = ABPLexer.lex(line: line)
        return parse(lexed: lexed, rawLine: line)
    }
    
    public static func parse(lexed: LexedABPLine, rawLine: String) -> ParsedABPRule {
        switch lexed {
        case .empty:
            return .empty
        case .comment(let comment):
            return .comment(comment)
        case .cosmetic(let isException, let isProcedural, let isScriptlet, let rawDomains, let rawBody):
            if isScriptlet {
                return .deferred(ParsedDeferredRule(kind: .scriptlet, rawText: rawLine))
            }
            if isProcedural {
                return .deferred(ParsedDeferredRule(kind: .proceduralCSS, rawText: rawLine))
            }
            let domains = rawDomains.isEmpty ? [] : rawDomains.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            return .cosmetic(ParsedCosmeticRule(domains: domains, isException: isException, selector: rawBody))
        case .network(let isException, let rawPattern, let rawOptions):
            let pattern = parseNetworkPattern(rawPattern)
            return .network(ParsedNetworkRule(pattern: pattern, isException: isException, rawModifiers: rawOptions))
        }
    }
    
    private static func parseNetworkPattern(_ pattern: String) -> ABPPattern {
        // Regex format /regex/
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 2 {
            let inner = String(pattern.dropFirst().dropLast())
            return .regularExpression(inner)
        }
        
        // Exact match ||domain.com/path|
        if pattern.hasSuffix("|") && pattern.count > 1 {
            var core = String(pattern.dropLast())
            if core.hasPrefix("||") {
                core = String(core.dropFirst(2))
            } else if core.hasPrefix("|") {
                core = String(core.dropFirst())
            }
            return .exactMatch(core)
        }
        
        // Domain anchor ||domain.com^ or ||domain.com
        if pattern.hasPrefix("||") {
            var domain = String(pattern.dropFirst(2))
            if domain.hasSuffix("^") {
                domain = String(domain.dropLast())
            }
            return .domainAnchor(domain)
        }
        
        // URL Prefix anchor |http
        if pattern.hasPrefix("|") {
            let prefix = String(pattern.dropFirst())
            return .urlPrefix(prefix)
        }
        
        // Standard wildcard / substring pattern
        return .wildcard(pattern)
    }
}
