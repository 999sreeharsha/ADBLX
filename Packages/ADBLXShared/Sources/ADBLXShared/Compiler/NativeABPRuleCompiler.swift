import Foundation

public enum NativeABPRuleCompiler: Sendable {
    public enum CompilerError: Error, LocalizedError {
        case invalidUTF8Input
        case encodingFailed(String)
        case unrestrictedBlockRule(urlFilter: String)
        case unrestrictedExceptionRule

        public var errorDescription: String? {
            switch self {
            case .unrestrictedExceptionRule:
                return "Compiler produced an ignore-previous-rules rule that matches every page with no domain "
                    + "restriction. It would cancel every earlier rule in the group on every site."
            case .invalidUTF8Input:
                return "The filter list input data is not valid UTF-8 text."
            case .encodingFailed(let reason):
                return "Failed to encode compiled rules to JSON: \(reason)"
            case .unrestrictedBlockRule(let urlFilter):
                return "Compiler produced an unrestricted catch-all block rule (url-filter: \(urlFilter)). "
                    + "Such a rule blocks all matching traffic on every site and must never ship."
            }
        }
    }

    /// Defense-in-depth guard (Fix C). Fails compilation if any rule would `block` with a
    /// catch-all `url-filter` and no `if-domain` scoping — the failure mode that black-screened
    /// YouTube (`$ping,third-party` -> `{"url-filter":".*"}` block). `ignore-previous-rules`
    /// and `css-display-none` catch-alls are legitimate and are not flagged.
    /// True for an `ignore-previous-rules` rule that matches every page load with no domain
    /// restriction. Safari applies it on every site and it cancels every earlier rule in
    /// the list, so one such rule makes a whole group inert.
    public static func isUnrestrictedException(_ rule: SafariContentBlockerRule) -> Bool {
        guard rule.action.type == "ignore-previous-rules",
              SafariRuleGenerator.isCatchAllURLFilter(rule.trigger.urlFilter),
              (rule.trigger.ifDomain ?? []).isEmpty,
              (rule.trigger.unlessDomain ?? []).isEmpty else {
            return false
        }
        guard let resourceTypes = rule.trigger.resourceType else { return true }
        return resourceTypes.contains("document")
    }

    /// Fails compilation if any rule is an unrestricted exception (see
    /// `isUnrestrictedException`). A failed compile leaves the last-good rules installed.
    public static func assertNoUnrestrictedExceptionRules(_ rules: [SafariContentBlockerRule]) throws {
        if rules.contains(where: isUnrestrictedException) {
            throw CompilerError.unrestrictedExceptionRule
        }
    }

    static func assertNoUnrestrictedBlockRules(_ rules: [SafariContentBlockerRule]) throws {
        for rule in rules where rule.action.type == "block" {
            let hasDomainScope = !(rule.trigger.ifDomain ?? []).isEmpty
            if SafariRuleGenerator.isCatchAllURLFilter(rule.trigger.urlFilter) && !hasDomainScope {
                throw CompilerError.unrestrictedBlockRule(urlFilter: rule.trigger.urlFilter)
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
                    let (rules, scope) = SafariRuleGenerator.generateWithScope(from: validated)
                    if record(scope, in: &report) {
                        return
                    }
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
                    let (rules, scope) = SafariRuleGenerator.generateWithScope(from: validated)
                    if record(scope, in: &report) {
                        return
                    }
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
        
        // Fix C: fail loudly rather than ship a catch-all block rule.
        try assertNoUnrestrictedBlockRules(compiledRules)
        try assertNoUnrestrictedExceptionRules(compiledRules)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        report.compilationDurationSeconds = elapsed

        return (compiledRules, report)
    }
    
    /// Counts a rule's domain-scope outcome. Returns true when the rule was dropped.
    private static func record(_ scope: SafariRuleGenerator.DomainScopeOutcome, in report: inout CompilationReport) -> Bool {
        switch scope {
        case .kept:
            return false
        case .trimmed:
            report.trimmedDomainsRuleCount += 1
            return false
        case .droppedAllUnsupported:
            report.droppedUnsupportedDomainsCount += 1
        case .droppedUnlessOnly:
            report.droppedUnlessOnlyCount += 1
        case .droppedGenericHidingException:
            report.unsupportedSemanticModifiers["generic_hiding_exception", default: 0] += 1
        }
        report.skippedRulesCount += 1
        return true
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
