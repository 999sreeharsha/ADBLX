import Foundation

public enum NativeABPRuleCompiler: Sendable {
    public enum CompilerError: Error, LocalizedError {
        case invalidUTF8Input
        case encodingFailed(String)
        
        public var errorDescription: String? {
            switch self {
            case .invalidUTF8Input:
                return "The filter list input data is not valid UTF-8 text."
            case .encodingFailed(let reason):
                return "Failed to encode compiled rules to JSON: \(reason)"
            }
        }
    }
    
    /// Compiles an ABP/AdGuard declarative text source into strongly-typed SafariContentBlockerRules and a CompilationReport.
    /// Implements a 2-pass compiler to ensure `$badfilter` directives accurately retract their target rules.
    public static func compile(
        source: Data,
        group: String
    ) throws -> (rules: [SafariContentBlockerRule], report: CompilationReport) {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        guard let text = String(data: source, encoding: .utf8) else {
            throw CompilerError.invalidUTF8Input
        }
        
        var report = CompilationReport(group: group)
        var compiledRules: [SafariContentBlockerRule] = []
        compiledRules.reserveCapacity(min(150_000, max(100, text.count / 40)))
        
        // Pass 1: Collect canonical signatures of all `$badfilter` retraction rules
        var badfilterSignatures = Set<String>()
        text.enumerateLines { line, _ in
            let parsed = ABPParser.parse(line: line)
            if case .network(let net) = parsed {
                if net.rawModifiers.contains(where: { $0.lowercased() == "badfilter" }) {
                    let sig = canonicalNetworkSignature(
                        isException: net.isException,
                        pattern: net.pattern,
                        rawModifiers: net.rawModifiers.filter { $0.lowercased() != "badfilter" }
                    )
                    badfilterSignatures.insert(sig)
                }
            }
        }
        
        // Pass 2: Parse, filter out retracted rules, and generate Safari rules
        text.enumerateLines { line, _ in
            report.totalLinesProcessed += 1
            let parsed = ABPParser.parse(line: line)
            
            switch parsed {
            case .empty:
                break
            case .comment:
                report.commentsAndHeadersCount += 1
            case .deferred:
                report.deferredToWebExtensionCount += 1
            case .invalid:
                report.invalidRulesCount += 1
            case .cosmetic:
                let disposition = ABPSemanticValidator.validate(parsed)
                switch disposition {
                case .supported(let validated):
                    let rules = SafariRuleGenerator.generate(from: validated)
                    if rules.isEmpty {
                        report.skippedRulesCount += 1
                        report.unsupportedSemanticModifiers["empty_selector", default: 0] += 1
                    } else {
                        compiledRules.append(contentsOf: rules)
                        report.compiledRuleCount += rules.count
                    }
                case .unsupportedSemantic(_, let modifier):
                    report.unsupportedSemanticModifiers[modifier, default: 0] += 1
                    report.skippedRulesCount += 1
                case .deferredToWebExtension:
                    report.deferredToWebExtensionCount += 1
                case .invalid:
                    report.invalidRulesCount += 1
                case .ignored:
                    report.commentsAndHeadersCount += 1
                }
            case .network(let net):
                // Check if this rule is a $badfilter directive itself
                if net.rawModifiers.contains(where: { $0.lowercased() == "badfilter" }) {
                    report.skippedRulesCount += 1
                    return
                }
                
                // Check if this rule has been retracted by an active $badfilter directive
                let sig = canonicalNetworkSignature(
                    isException: net.isException,
                    pattern: net.pattern,
                    rawModifiers: net.rawModifiers
                )
                if badfilterSignatures.contains(sig) {
                    report.badfilterCount += 1
                    report.skippedRulesCount += 1
                    return
                }
                
                let disposition = ABPSemanticValidator.validate(parsed)
                switch disposition {
                case .supported(let validated):
                    let rules = SafariRuleGenerator.generate(from: validated)
                    if rules.isEmpty {
                        report.skippedRulesCount += 1
                        report.unsupportedSemanticModifiers["unsupported_dfa_regex", default: 0] += 1
                    } else {
                        compiledRules.append(contentsOf: rules)
                        report.compiledRuleCount += rules.count
                    }
                case .unsupportedSemantic(_, let modifier):
                    report.unsupportedSemanticModifiers[modifier, default: 0] += 1
                    report.skippedRulesCount += 1
                case .deferredToWebExtension:
                    report.deferredToWebExtensionCount += 1
                case .invalid:
                    report.invalidRulesCount += 1
                case .ignored:
                    report.commentsAndHeadersCount += 1
                }
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        report.compilationDurationSeconds = elapsed
        
        return (compiledRules, report)
    }
    
    private static func canonicalNetworkSignature(
        isException: Bool,
        pattern: ABPPattern,
        rawModifiers: [String]
    ) -> String {
        let patternStr: String
        switch pattern {
        case .regularExpression(let regex): patternStr = "/\(regex)/"
        case .exactMatch(let s): patternStr = "|\(s)|"
        case .domainAnchor(let s): patternStr = "||\(s)"
        case .urlPrefix(let s): patternStr = "|\(s)"
        case .wildcard(let s): patternStr = s
        }
        let sortedMods = rawModifiers.map { rawMod -> String in
            let trimmed = rawMod.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("domain=") {
                let domains = trimmed.dropFirst(7).split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.sorted()
                return "domain=" + domains.joined(separator: "|")
            }
            return trimmed
        }.sorted().joined(separator: ",")
        return "\(isException ? "@@" : "")\(patternStr)$\(sortedMods)"
    }
    
    /// Compiles ABP text directly to UTF-8 JSON Data suitable for Content Blocker publication.
    public static func compileToJSON(
        source: Data,
        group: String
    ) throws -> (jsonData: Data, report: CompilationReport) {
        let (rules, report) = try compile(source: source, group: group)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            let jsonData = try encoder.encode(rules)
            return (jsonData, report)
        } catch {
            throw CompilerError.encodingFailed(error.localizedDescription)
        }
    }
}
