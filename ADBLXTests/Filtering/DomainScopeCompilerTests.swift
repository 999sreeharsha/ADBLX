import Testing
import Foundation
@testable import ADBLX
import ADBLXShared

/// Domain scoping in the ABP → Safari compiler. Safari's `if-domain`/`unless-domain` cannot
/// express entity domains (`site.*`) or paths, so those entries are dropped. Dropping must
/// never widen a rule: a rule whose positive scope disappears is dropped, not emitted
/// unscoped. An unscoped `ignore-previous-rules` (from `myloview.*#@#.cookiesInfo`) disabled
/// every earlier Annoyances rule on every page.
@Suite("Compiler domain scoping")
struct DomainScopeCompilerTests {
    private func compile(_ text: String) throws -> (rules: [SafariContentBlockerRule], report: CompilationReport) {
        try NativeABPRuleCompiler.compile(source: Data(text.utf8), group: "annoyances")
    }

    @Test("an exception whose only domain is an entity domain is dropped, not made global")
    func entityOnlyExceptionIsDropped() throws {
        let (rules, report) = try compile("myloview.*#@#.cookiesInfo")
        #expect(rules.isEmpty)
        #expect(report.droppedUnsupportedDomainsCount == 1)
    }

    @Test("a hiding rule whose only domain is an entity domain is dropped, not made global")
    func entityOnlyHidingRuleIsDropped() throws {
        let (rules, report) = try compile("site.*##.cookie-bar")
        #expect(rules.isEmpty)
        #expect(report.droppedUnsupportedDomainsCount == 1)
    }

    @Test("a network rule whose $domain list is all entity domains is dropped")
    func entityOnlyNetworkRuleIsDropped() throws {
        let (rules, report) = try compile("||consent.example^$script,domain=site.*")
        #expect(rules.isEmpty)
        #expect(report.droppedUnsupportedDomainsCount == 1)
    }

    @Test("a mixed domain list keeps only the supported domains")
    func mixedListKeepsSupportedDomains() throws {
        let (rules, report) = try compile("example.com,site.*##.cookie-bar")
        #expect(rules.count == 1)
        #expect(rules.first?.trigger.ifDomain == ["*example.com"])
        #expect(rules.first?.trigger.unlessDomain == nil)
        #expect(report.trimmedDomainsRuleCount == 1)
        #expect(report.droppedUnsupportedDomainsCount == 0)
    }

    @Test("a rule left with only unless-domains after dropping is dropped and counted separately")
    func unlessOnlyAfterDropIsDroppedAndCounted() throws {
        let (rules, report) = try compile("site.*,~safe.com##.cookie-bar")
        #expect(rules.isEmpty)
        #expect(report.droppedUnlessOnlyCount == 1)
        #expect(report.droppedUnsupportedDomainsCount == 0)
    }

    @Test("an exclusion-only rule keeps its supported exclusions")
    func exclusionOnlyRuleKeepsSupportedExclusions() throws {
        let (rules, _) = try compile("~site.*,~safe.com##.cookie-bar")
        #expect(rules.count == 1)
        #expect(rules.first?.trigger.ifDomain == nil)
        #expect(rules.first?.trigger.unlessDomain == ["*safe.com"])
    }

    @Test("a $document exception anchored on a path never becomes a page-wide exception")
    func pathAnchoredDocumentExceptionIsNotGlobal() throws {
        let (rules, _) = try compile("@@||jokerly.com/Okidak/adSelectorDirect.htm?id=$document,subdocument")
        #expect(!rules.contains(where: NativeABPRuleCompiler.isUnrestrictedException))
    }

    @Test("a generic hiding exception with no domains is dropped rather than cancelling every rule")
    func genericHidingExceptionIsDropped() throws {
        let (rules, report) = try compile("##.cookie-bar\n#@#.cookie-bar")
        #expect(rules.count == 1)
        #expect(report.unsupportedSemanticModifiers["generic_hiding_exception"] == 1)
    }

    @Test("a hiding rule with a supported domain is unchanged")
    func supportedDomainUnchanged() throws {
        let (rules, report) = try compile("example.com##.cookie-bar")
        #expect(rules.first?.trigger.ifDomain == ["*example.com"])
        #expect(report.droppedUnsupportedDomainsCount == 0)
        #expect(report.trimmedDomainsRuleCount == 0)
    }
}

@Suite("Compiler unrestricted-exception invariant")
struct UnrestrictedExceptionInvariantTests {
    private func rule(
        _ type: String,
        url: String = ".*",
        ifDomain: [String]? = nil,
        unlessDomain: [String]? = nil,
        resourceType: [String]? = nil
    ) -> SafariContentBlockerRule {
        SafariContentBlockerRule(
            trigger: .init(urlFilter: url, ifDomain: ifDomain, unlessDomain: unlessDomain, resourceType: resourceType),
            action: .init(type: type)
        )
    }

    @Test("an ignore-previous-rules matching every page with no domain restriction is unrestricted")
    func detectsUnrestricted() {
        #expect(NativeABPRuleCompiler.isUnrestrictedException(rule("ignore-previous-rules")))
        #expect(NativeABPRuleCompiler.isUnrestrictedException(rule("ignore-previous-rules", url: "^https?://.*")))
        #expect(NativeABPRuleCompiler.isUnrestrictedException(
            rule("ignore-previous-rules", resourceType: ["document", "svg-document"])
        ))
    }

    @Test("domain-restricted, URL-specific or non-page exceptions are allowed")
    func allowsRestricted() {
        #expect(!NativeABPRuleCompiler.isUnrestrictedException(rule("ignore-previous-rules", ifDomain: ["*a.com"])))
        #expect(!NativeABPRuleCompiler.isUnrestrictedException(rule("ignore-previous-rules", unlessDomain: ["*a.com"])))
        #expect(!NativeABPRuleCompiler.isUnrestrictedException(rule("ignore-previous-rules", url: "^https?://a\\.com/")))
        #expect(!NativeABPRuleCompiler.isUnrestrictedException(rule("ignore-previous-rules", resourceType: ["image"])))
        #expect(!NativeABPRuleCompiler.isUnrestrictedException(rule("css-display-none")))
    }

    @Test("compiling a group that contains an unrestricted exception fails")
    func compileFails() {
        #expect(throws: NativeABPRuleCompiler.CompilerError.self) {
            _ = try NativeABPRuleCompiler.compile(source: Data("##.ad\n@@*$document".utf8), group: "annoyances")
        }
    }

    @Test("a pre-compiled JSON group with an unrestricted exception fails to compile")
    func precompiledJSONFails() async throws {
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".ad"}},"#
            + #"{"trigger":{"url-filter":".*"},"action":{"type":"ignore-previous-rules"}}]"#
        await #expect(throws: (any Error).self) {
            _ = try await NativeRuleCompilerAdapter().compile(source: Data(json.utf8), group: .annoyances)
        }
    }

    @Test("a failed group compile leaves the last-good compiled rules in place")
    func failedCompileKeepsLastGood() async throws {
        let ids = GroupExtensionIdentifiers(
            ads: "com.ADBLX.Ads", privacy: "com.ADBLX.Privacy",
            annoyances: "com.ADBLX.Annoyances", regional: "com.ADBLX.Regional"
        )
        let store = FilterStore.temporary()
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: NativeRuleCompilerAdapter(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        func composition(_ text: String) -> GroupComposition {
            let data = Data(text.utf8)
            return GroupComposition(group: .annoyances, sources: [
                FilterSource(filterID: "fanboy-annoyances", version: "1", checksumSHA256: Checksum.sha256Hex(of: data), data: data)
            ])
        }

        _ = try await pipeline.install(composition("##.cookie-bar"), reloadStrategy: .deferred)
        let lastGood = try await store.read("Annoyances.json", in: .compiled)

        await #expect(throws: (any Error).self) {
            _ = try await pipeline.install(composition("##.cookie-bar\n@@*$document"), reloadStrategy: .deferred)
        }
        #expect(try await store.read("Annoyances.json", in: .compiled) == lastGood)
    }
}

/// Runs the shipped lists through the real compiler. Guards against any future list line or
/// compiler change that makes a whole group inert on ordinary pages.
@Suite("Bundled lists compile without page-wide exceptions", .serialized)
struct BundledListScopingRegressionTests {
    private static let groups: [(name: String, file: String)] = [
        ("Ads", "easylist"), ("Privacy", "easyprivacy"), ("Annoyances", "fanboy-annoyances"),
    ]

    private func bundledList(_ file: String) throws -> Data {
        let url = Bundle.main.url(forResource: file, withExtension: "txt")
            ?? Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "Filters")
        return try Data(contentsOf: try #require(url, "bundled \(file).txt missing from the app bundle"))
    }

    @Test("no group contains an unrestricted exception; Annoyances applies on ordinary pages")
    func bundledListsStayEffective() throws {
        for group in Self.groups {
            let (rules, report) = try NativeABPRuleCompiler.compile(source: try bundledList(group.file), group: group.name)
            #expect(!rules.contains(where: NativeABPRuleCompiler.isUnrestrictedException), "\(group.name)")
            print("[scoping] \(group.name): compiled=\(rules.count) droppedAllUnsupported=\(report.droppedUnsupportedDomainsCount) droppedUnlessOnly=\(report.droppedUnlessOnlyCount) trimmed=\(report.trimmedDomainsRuleCount) genericHidingExceptions=\(report.unsupportedSemanticModifiers["generic_hiding_exception"] ?? 0)")

            guard group.name == "Annoyances" else { continue }
            for host in ["www.cookiebot.com", "example.com"] {
                let effective = EffectiveRuleCounter.hidingRulesInEffect(rules, url: "https://\(host)/", host: host)
                print("[scoping] Annoyances effective hiding rules on \(host): \(effective)")
                #expect(effective > 0, "Annoyances must apply on \(host)")
            }
        }
    }
}

/// Approximates Safari's page-level evaluation: rules apply in order, and a matching
/// `ignore-previous-rules` for the document load cancels every earlier rule.
private enum EffectiveRuleCounter {
    static func hidingRulesInEffect(_ rules: [SafariContentBlockerRule], url: String, host: String) -> Int {
        var cache: [String: NSRegularExpression?] = [:]
        var inEffect = 0
        for rule in rules {
            let type = rule.action.type
            guard type == "css-display-none" || type == "ignore-previous-rules" else { continue }
            if type == "ignore-previous-rules",
               let resourceTypes = rule.trigger.resourceType, !resourceTypes.contains("document") { continue }
            guard domainsAllow(rule.trigger, host: host) else { continue }
            guard urlMatches(rule.trigger, url: url, cache: &cache) else { continue }
            if type == "ignore-previous-rules" { inEffect = 0 } else { inEffect += 1 }
        }
        return inEffect
    }

    private static func matches(_ entries: [String], host: String) -> Bool {
        entries.contains { entry in
            let base = entry.hasPrefix("*") ? String(entry.dropFirst()) : entry
            return host == base || (entry.hasPrefix("*") && host.hasSuffix("." + base))
        }
    }

    private static func domainsAllow(_ trigger: SafariContentBlockerRule.Trigger, host: String) -> Bool {
        if let ifDomain = trigger.ifDomain, !matches(ifDomain, host: host) { return false }
        if let unlessDomain = trigger.unlessDomain, matches(unlessDomain, host: host) { return false }
        return true
    }

    private static func urlMatches(
        _ trigger: SafariContentBlockerRule.Trigger, url: String, cache: inout [String: NSRegularExpression?]
    ) -> Bool {
        if trigger.urlFilter == ".*" { return true }
        let key = trigger.urlFilter + (trigger.urlFilterIsCaseSensitive == true ? "|cs" : "")
        if cache[key] == nil {
            let options: NSRegularExpression.Options = trigger.urlFilterIsCaseSensitive == true ? [] : [.caseInsensitive]
            cache[key] = .some(try? NSRegularExpression(pattern: trigger.urlFilter, options: options))
        }
        guard let regex = cache[key] ?? nil else { return false }
        return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
}
