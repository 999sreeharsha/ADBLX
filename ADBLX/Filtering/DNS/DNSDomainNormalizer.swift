import Foundation

public enum DNSDomainNormalizer {
    /// Lines matching AdBlock cosmetic/procedural filter syntax are not
    /// domain data under any interpretation and must be rejected outright.
    private static let cosmeticFilterMarkers = ["##", "#?#", "#@#", "#$#", "#%#"]

    /// Normalizes a raw blocklist or allowlist rule line into a canonical reversed-label domain string.
    ///
    /// Examples:
    /// - `"||example.com^"` -> `"com.example"`
    /// - `"0.0.0.0 ads.doubleclick.net"` -> `"net.doubleclick.ads"`
    /// - `"127.0.0.1 tracker.com # comment"` -> `"com.tracker"`
    /// - `"Sub.Domain.ORG"` -> `"org.domain.sub"`
    ///
    /// Returns `nil` if the line is empty, a comment, an IP literal, or contains unsupported wildcards/invalid syntax.
    public static func normalizeToReversedDomain(line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Skip comments and empty lines
        if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("!") || trimmed.hasPrefix("//") {
            return nil
        }
        
        // 2. Reject cosmetic/procedural rules before ANY comment-stripping logic runs
        if cosmeticFilterMarkers.contains(where: trimmed.contains) {
            return nil
        }
        
        // 3. Reject ABP exception rules outright (never invert @@ into a block directive)
        if trimmed.hasPrefix("@@") {
            return nil
        }
        
        // Strip inline comments (hosts format: "127.0.0.1 domain.com # comment")
        if let hashIdx = trimmed.firstIndex(of: "#") {
            trimmed = String(trimmed[..<hashIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.isEmpty { return nil }
        
        // 4. Parse ABP Syntax: extract domain up to '^' or '$' delimiter
        if trimmed.hasPrefix("||") {
            trimmed = String(trimmed.dropFirst(2))
            
            // If '$' option modifiers are present (e.g. $third-party, $image, $script, $domain=),
            // this is a context-dependent content blocker rule, not an unconditional DNS rule.
            // Suffix walk on DNS cannot evaluate HTTP context; reject to prevent collateral damage.
            if trimmed.contains("$") {
                return nil
            }
            
            // Extract domain up to separator '^'
            if let caretIdx = trimmed.firstIndex(of: "^") {
                trimmed = String(trimmed[..<caretIdx])
            }
        }
        
        // 5. Strip Hosts IP prefixes (e.g. "0.0.0.0 ", "127.0.0.1 ")
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard let candidateToken = tokens.first(where: { token in
            token != "0.0.0.0" && token != "127.0.0.1" && token != "::1" && token != "broadcasthost" && token != "local" && token != "localhost"
        }) else {
            return nil
        }
        
        var domain = String(candidateToken).lowercased()
        while domain.hasPrefix(".") { domain.removeFirst() }
        while domain.hasSuffix(".") { domain.removeLast() }
        guard !domain.isEmpty else { return nil }
        
        // 6. Strict Syntax Validation (Strict rejection of wildcards, slashes, ports, IPs, carets, dollars)
        let invalidChars: [Character] = ["*", "/", ":", "?", "@", "^", "$"]
        if invalidChars.contains(where: { domain.contains($0) }) {
            return nil
        }
        
        // Verify not a raw IPv4 or IPv6 address
        if isValidIPAddress(domain) {
            return nil
        }
        
        // Split labels
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            // Must have at least a second-level domain (e.g. "example.com")
            return nil
        }
        
        for label in labels {
            if label.isEmpty || label.count > 63 { return nil }
            // Must contain only valid hostname characters: a-z, 0-9, hyphen
            for char in label.utf8 {
                let isAlpha = (char >= 97 && char <= 122) // a-z
                let isNum = (char >= 48 && char <= 57)   // 0-9
                let isHyphen = (char == 45)              // -
                let isUnderscore = (char == 95)          // _ (DNS service records/hostnames)
                if !isAlpha && !isNum && !isHyphen && !isUnderscore {
                    return nil
                }
            }
            if label.hasPrefix("-") || label.hasSuffix("-") {
                return nil
            }
        }
        
        // 5. Reverse labels: ["ads", "doubleclick", "net"] -> "net.doubleclick.ads"
        let reversedLabels = labels.reversed()
        return reversedLabels.joined(separator: ".")
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
