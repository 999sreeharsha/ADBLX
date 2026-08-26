import Foundation

public enum ABPLexer: Sendable {
    /// Classifies and tokenizes a raw filter list line without unnecessary full-string copying.
    public static func lex(line: String) -> LexedABPLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }
        
        // 1. Comments and Headers (! or [ or single #)
        if trimmed.hasPrefix("!") || trimmed.hasPrefix("[") {
            return .comment(trimmed)
        }
        
        // 2. Cosmetic Rules (##, #@#, #?#, #$#, ##+js)
        if let cosmetic = lexCosmetic(trimmed) {
            return cosmetic
        }
        
        // Single # is a comment (e.g. hosts file format)
        if trimmed.hasPrefix("#") {
            return .comment(trimmed)
        }
        
        // 3. Network Exception (@@) or Block Rules
        return lexNetwork(trimmed)
    }
    
    private static func lexCosmetic(_ text: String) -> LexedABPLine? {
        let separators = ["#@#", "#?#", "#$#", "##"]
        for sep in separators {
            if let range = text.range(of: sep) {
                let rawDomains = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rawBody = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                
                let isException = (sep == "#@#")
                let isProcedural = (sep == "#?#" || rawBody.contains(":has(") || rawBody.contains(":xpath("))
                let isScriptlet = (sep == "#$#" || rawBody.hasPrefix("+js("))
                
                return .cosmetic(
                    isException: isException,
                    isProcedural: isProcedural,
                    isScriptlet: isScriptlet,
                    rawDomains: rawDomains,
                    rawBody: rawBody
                )
            }
        }
        return nil
    }
    
    private static func lexNetwork(_ text: String) -> LexedABPLine {
        var pattern = text
        var isException = false
        
        if pattern.hasPrefix("@@") {
            isException = true
            pattern = String(pattern.dropFirst(2))
        }
        
        var rawOptions: [String] = []
        if let dollarIdx = pattern.lastIndex(of: "$") {
            let optionsSubstring = pattern[pattern.index(after: dollarIdx)...]
            pattern = String(pattern[..<dollarIdx])
            rawOptions = optionsSubstring.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        
        return .network(
            isException: isException,
            rawPattern: pattern,
            rawOptions: rawOptions
        )
    }
}
