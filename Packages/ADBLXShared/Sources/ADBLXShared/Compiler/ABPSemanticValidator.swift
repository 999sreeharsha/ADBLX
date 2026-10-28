import Foundation

public enum ABPSemanticValidator: Sendable {
    private static let unsupportedSemanticModifiers: Set<String> = [
        "popup", "csp", "redirect", "redirect-rule", "rewrite", "important",
        "generichide", "genericblock", "badfilter", "match-case", "method"
    ]
    
    public static func validate(_ parsed: ParsedABPRule) -> ValidationDisposition {
        switch parsed {
        case .empty:
            return .ignored(reason: "Empty line")
        case .comment(let text):
            return .ignored(reason: "Comment or header: \(text)")
        case .deferred(let def):
            return .deferredToWebExtension(reason: "Deferred construct: \(def.rawText)")
        case .invalid(let inv):
            return .invalid(reason: inv.reason)
        case .cosmetic(let cos):
            return validateCosmetic(cos)
        case .network(let net):
            return validateNetwork(net)
        }
    }
    
    private static func validateCosmetic(_ cos: ParsedCosmeticRule) -> ValidationDisposition {
        if cos.selector.trimmingCharacters(in: .whitespaces).isEmpty {
            return .invalid(reason: "Empty CSS selector")
        }
        
        var ifDomains: [String] = []
        var unlessDomains: [String] = []
        
        for d in cos.domains {
            let trimmed = d.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("~") {
                let dom = String(trimmed.dropFirst())
                unlessDomains.append("*" + dom)
            } else {
                ifDomains.append("*" + trimmed)
            }
        }
        
        let validated = ValidatedCosmeticRule(
            ifDomains: ifDomains,
            unlessDomains: unlessDomains,
            isException: cos.isException,
            selector: cos.selector
        )
        return .supported(.cosmetic(validated))
    }
    
    private static func validateNetwork(_ net: ParsedNetworkRule) -> ValidationDisposition {
        var loadType: SafariLoadType?
        var positiveResourceTypes = Set<SafariResourceType>()
        var negatedResourceTypes = Set<SafariResourceType>()
        var ifDomains: [String] = []
        var unlessDomains: [String] = []
        var isDocumentException = false
        
        for rawMod in net.rawModifiers {
            let key = rawMod.split(separator: "=").first.map(String.init) ?? rawMod
            
            // Check unsupported semantic modifiers
            if unsupportedSemanticModifiers.contains(key) {
                return .unsupportedSemantic(reason: "Unsupported semantic modifier: $\(key)", modifier: key)
            }
            
            // Third party
            if key == "third-party" {
                loadType = .thirdParty
                continue
            }
            if key == "~third-party" {
                loadType = .firstParty
                continue
            }
            
            // Domain option: $domain=foo.com|~bar.com
            if key == "domain" {
                if let eqIdx = rawMod.firstIndex(of: "=") {
                    let val = String(rawMod[rawMod.index(after: eqIdx)...])
                    let domains = val.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
                    for d in domains {
                        if d.hasPrefix("~") {
                            unlessDomains.append("*" + String(d.dropFirst()))
                        } else {
                            ifDomains.append("*" + d)
                        }
                    }
                }
                continue
            }
            
            // Fix B: `$ping` (hyperlink auditing / navigator.sendBeacon) has no dedicated
            // WebKit content-blocker resource type. It was previously folded into `raw`,
            // which also covers all XHR/fetch/WebSocket — turning a narrow "block beacons"
            // rule into a broad "block network I/O" rule. WebKit cannot express `ping`
            // precisely, so treat it as an unsupported modifier (skipped + counted) rather
            // than silently over-blocking.
            if key == "ping" || key == "~ping" {
                return .unsupportedSemantic(reason: "Unsupported modifier: $ping (no WebKit equivalent)", modifier: "ping")
            }

            // Positive resource types
            if let pos = mapPositiveResourceType(key) {
                positiveResourceTypes.formUnion(pos)
                continue
            }
            
            // Negated resource types
            if key.hasPrefix("~") {
                let baseKey = String(key.dropFirst())
                if let neg = mapPositiveResourceType(baseKey) {
                    negatedResourceTypes.formUnion(neg)
                    continue
                }
            }
            
            // Document exception option
            if key == "document" && net.isException {
                isDocumentException = true
                continue
            }
            
            // If unknown modifier, skip to preserve semantic safety
            return .unsupportedSemantic(reason: "Unknown modifier: $\(key)", modifier: key)
        }
        
        // Compute final resource types
        var finalResourceTypes = Set<SafariResourceType>()
        if !positiveResourceTypes.isEmpty {
            finalResourceTypes = positiveResourceTypes
        }
        
        if !negatedResourceTypes.isEmpty {
            let complement = SafariResourceType.filterableSubresources.subtracting(negatedResourceTypes)
            if finalResourceTypes.isEmpty {
                finalResourceTypes = complement
            } else {
                finalResourceTypes = finalResourceTypes.intersection(complement)
            }
        }
        
        var finalPattern = net.pattern
        if isDocumentException {
            if case .domainAnchor(let dom) = net.pattern {
                if ifDomains.isEmpty {
                    ifDomains.append("*" + dom)
                }
                finalPattern = .wildcard(".*")
            }
        }
        
        let validated = ValidatedNetworkRule(
            pattern: finalPattern,
            isException: net.isException,
            loadType: loadType,
            resourceTypes: finalResourceTypes,
            ifDomains: ifDomains,
            unlessDomains: unlessDomains
        )
        return .supported(.network(validated))
    }
    
    private static func mapPositiveResourceType(_ key: String) -> Set<SafariResourceType>? {
        switch key {
        case "script":
            return [.script]
        case "image":
            return [.image]
        case "stylesheet", "css":
            return [.styleSheet]
        case "xmlhttprequest", "xhr", "websocket", "other":
            return [.raw]
        case "subdocument":
            return [.document, .svgDocument]
        case "font":
            return [.font]
        case "media":
            return [.media]
        default:
            return nil
        }
    }
}
