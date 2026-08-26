import Foundation
import ADBLXShared

/// Merges every `FilterSource` in a `GroupComposition` into one rule set before
/// compilation. Composes ABP text sources by concatenation, or JSON sources by array merge,
/// and appends canonical allowlist exception rules at the trailing position.
protocol CompositionService: Sendable {
    nonisolated func compose(
        _ sources: [FilterSource],
        group: FilterGroup,
        allowlistRules: [SafariContentBlockerRule]
    ) throws -> ComposedRules
}

extension CompositionService {
    nonisolated func compose(_ sources: [FilterSource], group: FilterGroup) throws -> ComposedRules {
        try compose(sources, group: group, allowlistRules: [])
    }
}

enum CompositionServiceError: Error, Equatable {
    case invalidSource(filterID: String)
}

struct JSONArrayCompositionService: CompositionService {
    nonisolated func compose(
        _ sources: [FilterSource],
        group: FilterGroup,
        allowlistRules: [SafariContentBlockerRule] = []
    ) throws -> ComposedRules {
        if sources.isEmpty {
            if !allowlistRules.isEmpty {
                let allowlistData = try SafariAllowlistCompiler.encode(rules: allowlistRules)
                return ComposedRules(group: group, data: allowlistData, sourceCount: 0, ruleCount: allowlistRules.count)
            }
            return ComposedRules(group: group, data: Data("[]".utf8), sourceCount: 0, ruleCount: 0)
        }
        
        // Detect whether first source is a valid JSON array
        var isJSON = false
        if let first = sources.first,
           !first.data.isEmpty,
           let text = String(data: first.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.hasPrefix("[Adblock"),
           ((try? JSONSerialization.jsonObject(with: first.data)) as? [Any]) != nil {
            isJSON = true
        }
        
        if isJSON {
            var merged: [Any] = []
            for source in sources {
                guard let array = try? JSONSerialization.jsonObject(with: source.data) as? [Any] else {
                    throw CompositionServiceError.invalidSource(filterID: source.filterID)
                }
                merged.append(contentsOf: array)
            }
            
            // Append allowlist exception rules at the tail
            if !allowlistRules.isEmpty {
                let allowlistData = try SafariAllowlistCompiler.encode(rules: allowlistRules)
                if let allowlistArray = try? JSONSerialization.jsonObject(with: allowlistData) as? [Any] {
                    merged.append(contentsOf: allowlistArray)
                }
            }
            
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
            return ComposedRules(group: group, data: data, sourceCount: sources.count, ruleCount: merged.count)
        } else {
            // ABP Text Composition
            var textParts: [String] = []
            for source in sources {
                guard let text = String(data: source.data, encoding: .utf8), !text.isEmpty else {
                    throw CompositionServiceError.invalidSource(filterID: source.filterID)
                }
                
                // Validate that the source has recognizable ABP or filter content
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasABPConstruct = trimmed.hasPrefix("!") ||
                                      trimmed.hasPrefix("[") ||
                                      trimmed.hasPrefix("||") ||
                                      trimmed.hasPrefix("|") ||
                                      trimmed.hasPrefix("@@") ||
                                      trimmed.contains("##") ||
                                      trimmed.contains("#@#") ||
                                      trimmed.contains("#?#") ||
                                      trimmed.contains("#$#") ||
                                      trimmed.contains("$") ||
                                      trimmed.contains("^") ||
                                      trimmed.contains("*") ||
                                      trimmed.hasPrefix("/")
                
                guard hasABPConstruct else {
                    throw CompositionServiceError.invalidSource(filterID: source.filterID)
                }
                
                textParts.append(text)
            }
            
            // Append allowlist exception rules as ABP document exceptions at the tail
            for rule in allowlistRules {
                if let ifDomains = rule.trigger.ifDomain {
                    for dom in ifDomains {
                        let cleanDom = dom.hasPrefix("*") ? String(dom.dropFirst()) : dom
                        textParts.append("@@||\(cleanDom)^$document")
                    }
                }
            }
            
            let combinedText = textParts.joined(separator: "\n")
            let data = Data(combinedText.utf8)
            return ComposedRules(group: group, data: data, sourceCount: sources.count, ruleCount: 0)
        }
    }
}
