import Foundation

public enum SafariAllowlistCompiler: Sendable {
    /// Compiles a list of domain strings into deterministic, sorted SafariContentBlockerRule exception rules.
    ///
    /// Invariant: 1 domain -> 1 exception rule (`action.type == "ignore-previous-rules"`).
    public static func compile(domains: [String]) -> [SafariContentBlockerRule] {
        var uniqueNormalized: Set<String> = []
        for raw in domains {
            if let normalized = try? SafariDomainNormalizer.normalize(input: raw) {
                uniqueNormalized.insert(normalized)
            } else {
                let fallback = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !fallback.isEmpty {
                    uniqueNormalized.insert(fallback)
                }
            }
        }
        
        let sortedDomains = uniqueNormalized.sorted()
        return sortedDomains.map { domain in
            SafariContentBlockerRule(
                trigger: .init(
                    urlFilter: ".*",
                    ifDomain: ["*\(domain)"]
                ),
                action: .init(type: "ignore-previous-rules")
            )
        }
    }
    
    /// Encodes a list of rules to JSON Data with sorted keys for absolute byte determinism.
    public static func encode(rules: [SafariContentBlockerRule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(rules)
    }
}
