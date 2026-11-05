// ADBLXTests/BrokenSite/BrokenSiteReporterTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("Broken site report")
struct BrokenSiteReporterTests {
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    private func makeReporter(settings: SettingsService = RecordingSettingsService()) -> RealBrokenSiteReporter {
        RealBrokenSiteReporter(
            settingsService: settings,
            stateProvider: FixedStateProvider(enabled: [ids.ads, ids.privacy]),
            extensionIdentifiers: ids,
            appVersion: "1.2"
        )
    }

    @Test("input is reduced to the registrable domain", arguments: [
        // URL with path, query parameters, fragment, and scheme
        ("https://sub.example.com/some/path?param=secret#header", "example.com"),
        // Multi-part ccTLD public suffix (co.uk)
        ("https://news.bbc.co.uk:8443/article?id=99#frag", "bbc.co.uk"),
        // Multi-part ccTLD public suffix (gov.in)
        ("https://portal.service.gov.in/app/login", "service.gov.in"),
        // Multi-part hosting platform suffix (github.io)
        ("https://docs.github.io/en/get-started", "docs.github.io"),
        // Upper-case domain with whitespace
        ("   EXAMPLE.ORG   ", "example.org")
    ])
    func sanitization(input: String, expected: String) throws {
        #expect(try makeReporter().sanitizeDomain(input) == expected)
    }

    @Test("empty input, IP addresses and localhost are rejected", arguments: ["", "192.168.1.1", "localhost"])
    func rejectedInput(input: String) {
        #expect(throws: (any Error).self) { try makeReporter().sanitizeDomain(input) }
    }

    @Test("a report holds only the domain, issue, app version and enabled groups")
    func reportContents() async throws {
        let report = try await makeReporter().makeReport(
            domain: "https://sub.example.com/private/path?token=secret#frag",
            category: .pageLayoutBroken
        )

        #expect(report.bodyText == """
        ADBLX broken site report
        Site: example.com
        Issue: Page Layout Broken
        App version: 1.2
        Enabled filter groups: ads, privacy
        """)
    }

    @Test("making a report never allowlists")
    func reportDoesNotAllowlist() async throws {
        let settings = RecordingSettingsService()
        _ = try await makeReporter(settings: settings).makeReport(domain: "example.com", category: .other)

        #expect(settings.added == [])
    }

    @Test("the mail URL carries the encoded subject and body")
    func mailURL() throws {
        let report = BrokenSiteReport(domain: "example.com", category: .other, appVersion: "1.2", enabledGroups: ["ads"])

        let url = try #require(report.mailURL(recipient: "reports@example.org"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "mailto")
        #expect(components.path == "reports@example.org")
        #expect(components.queryItems?.first { $0.name == "subject" }?.value == "Broken site: example.com")
        #expect(components.queryItems?.first { $0.name == "body" }?.value == report.bodyText)
        #expect(!url.absoluteString.contains("\n"))
        #expect(!url.absoluteString.contains(" "))
    }

    @Test("with no recipient the mail URL leaves To empty")
    func mailURLWithoutRecipient() throws {
        let report = BrokenSiteReport(domain: "example.com", category: .other, appVersion: "1.2", enabledGroups: [])

        let url = try #require(report.mailURL(recipient: nil))

        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path == "")
    }

    @Test("reviewing a report sends nothing and allowlists nothing")
    @MainActor
    func reviewSendsNothing() async {
        let settings = RecordingSettingsService()
        let viewModel = BrokenSiteReportViewModel(reporter: makeReporter(settings: settings), initialDomain: "https://my-test-site.org/index")
        #expect(viewModel.isDomainValid)
        #expect(viewModel.selectedCategory == .pageLayoutBroken)

        await viewModel.prepareReport()

        #expect(viewModel.report?.domain == "my-test-site.org")
        #expect(viewModel.delivery == nil)
        #expect(settings.added == [])
    }

    @Test("send opens mail, without touching the clipboard or the allowlist")
    @MainActor
    func sendOpensMail() async {
        let settings = RecordingSettingsService()
        let viewModel = BrokenSiteReportViewModel(reporter: makeReporter(settings: settings), initialDomain: "example.com")
        await viewModel.prepareReport()

        var opened: [URL] = []
        var copied: [String] = []
        await viewModel.send(open: { opened.append($0); return true }, copy: { copied.append($0) })

        #expect(opened.first?.scheme == "mailto")
        #expect(copied == [])
        #expect(viewModel.delivery == .mailOpened)
        #expect(settings.added == [])
    }

    @Test("send copies the report when no mail app opens")
    @MainActor
    func sendFallsBackToClipboard() async throws {
        let viewModel = BrokenSiteReportViewModel(reporter: makeReporter(), initialDomain: "example.com")
        await viewModel.prepareReport()
        let body = try #require(viewModel.report?.bodyText)

        var copied: [String] = []
        await viewModel.send(open: { _ in false }, copy: { copied.append($0) })

        #expect(copied == [body])
        #expect(viewModel.delivery == .copiedToClipboard)
    }

    @Test("allowing a site does not report it")
    @MainActor
    func allowDoesNotReport() async {
        let settings = RecordingSettingsService()
        let viewModel = BrokenSiteReportViewModel(reporter: makeReporter(settings: settings), initialDomain: "https://sub.example.com/a")

        await viewModel.allowSite()

        #expect(settings.added == ["example.com"])
        #expect(viewModel.allowlistedDomain == "example.com")
        #expect(viewModel.report == nil)
        #expect(viewModel.delivery == nil)
    }

    @Test("a failed allow is reported, not claimed")
    @MainActor
    func failedAllow() async {
        let settings = RecordingSettingsService(rejectsAdds: true)
        let viewModel = BrokenSiteReportViewModel(reporter: makeReporter(settings: settings), initialDomain: "example.com")

        await viewModel.allowSite()

        #expect(viewModel.allowlistedDomain == nil)
        #expect(viewModel.errorMessage != nil)
    }

    // A store-only write used to leave the compiled rules blocking the site.
    @Test("allowing a site recompiles the rules")
    @MainActor
    func allowRecompiles() async throws {
        let store = FilterStore.temporary()
        let allowlistStore = AllowlistStore(store: store)
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator(),
            allowlistStore: allowlistStore, gate: FilterTransactionGate()
        )
        let rules = Data("[{\"trigger\":{\"url-filter\":\"x\"},\"action\":{\"type\":\"block\"}}]".utf8)
        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [FilterSource(
            filterID: "easylist", version: "v1", checksumSHA256: Checksum.sha256Hex(of: rules), data: rules
        )]), reloadStrategy: .deferred)
        let settings = RealSettingsService(allowlistStore: allowlistStore, pipeline: pipeline)
        let viewModel = BrokenSiteReportViewModel(reporter: makeReporter(settings: settings), initialDomain: "example.com")

        await viewModel.allowSite()

        let compiled = try await store.read("Ads.json", in: .compiled)
        #expect(String(decoding: compiled, as: UTF8.self).contains("example"))
        #expect(viewModel.allowlistedDomain == "example.com")
    }
}

private nonisolated final class RecordingSettingsService: SettingsService, @unchecked Sendable {
    private let lock = NSLock()
    private var domains: [String] = []
    private let rejectsAdds: Bool

    init(rejectsAdds: Bool = false) { self.rejectsAdds = rejectsAdds }

    var added: [String] { lock.withLock { domains } }

    func fetchSnapshot() async -> SettingsSnapshot {
        SettingsSnapshot(iCloudSyncEnabled: false, allowlist: added.map { AllowlistEntry(id: $0, domain: $0) })
    }
    func addAllowlistEntry(domain: String) async {
        if !rejectsAdds { lock.withLock { domains.append(domain) } }
    }
    func removeAllowlistEntry(id: String) async {}
}

private nonisolated struct FixedStateProvider: ContentBlockerStateProviding {
    let enabled: Set<String>

    func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState {
        enabled.contains(extensionIdentifier) ? .enabled : .disabled
    }
}
