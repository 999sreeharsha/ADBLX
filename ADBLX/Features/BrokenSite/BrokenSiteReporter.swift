// ADBLX/Features/BrokenSite/BrokenSiteReporter.swift
import Foundation

/// Builds broken site reports for the user to send themselves, and allowlists a site when the
/// user asks. The two are separate: reporting never allowlists, and nothing here touches the
/// network. There is no backend, so a report leaves the device only through the user's mail app.
public protocol BrokenSiteReporting: Sendable {
    func sanitizeDomain(_ input: String) throws -> String
    func makeReport(domain: String, category: BreakageCategory) async throws -> BrokenSiteReport
    /// Returns the domain that was allowlisted.
    func allowlist(domain: String) async throws -> String
}

public enum BrokenSiteError: Error, Equatable {
    case allowlistFailed
}

actor RealBrokenSiteReporter: BrokenSiteReporting {
    private let settingsService: SettingsService
    private let stateProvider: ContentBlockerStateProviding
    private let extensionIdentifiers: GroupExtensionIdentifiers
    private let appVersion: String

    init(
        settingsService: SettingsService,
        stateProvider: ContentBlockerStateProviding,
        extensionIdentifiers: GroupExtensionIdentifiers,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    ) {
        self.settingsService = settingsService
        self.stateProvider = stateProvider
        self.extensionIdentifiers = extensionIdentifiers
        self.appVersion = appVersion
    }

    /// Normalizes and extracts the privacy-preserving eTLD+1 domain from user input.
    public nonisolated func sanitizeDomain(_ input: String) throws -> String {
        try SafariDomainNormalizer.extractETLDPlusOne(input: input)
    }

    public func makeReport(domain: String, category: BreakageCategory) async throws -> BrokenSiteReport {
        let cleanDomain = try sanitizeDomain(domain)
        var enabledGroups: [String] = []
        for group in FilterGroup.allCases where await stateProvider.state(of: extensionIdentifiers[group]) == .enabled {
            enabledGroups.append(group.rawValue)
        }
        return BrokenSiteReport(domain: cleanDomain, category: category, appVersion: appVersion, enabledGroups: enabledGroups)
    }

    /// Through `SettingsService`, as a Settings edit is: storing the domain alone would leave the
    /// compiled rules blocking the site.
    ///
    /// Allowlists the host itself, not the registrable domain: an entry also covers every
    /// subdomain, so `myblog.wordpress.com` widened to `wordpress.com` would unblock every blog
    /// there (SEC-10). A leading `www.` is dropped so the bare domain is covered too, unless that
    /// would leave a public suffix. A user who wants a whole site can add its parent in Settings.
    public func allowlist(domain: String) async throws -> String {
        let cleanDomain = try Self.allowlistHost(domain)
        await settingsService.addAllowlistEntry(domain: cleanDomain)
        // The service rolls back and returns normally when the recompile fails.
        guard await settingsService.fetchSnapshot().allowlist.contains(where: { $0.domain == cleanDomain }) else {
            throw BrokenSiteError.allowlistFailed
        }
        return cleanDomain
    }

    private static func allowlistHost(_ input: String) throws -> String {
        let host = try SafariDomainNormalizer.normalize(input: input)
        guard host.hasPrefix("www.") else { return host }
        let bare = String(host.dropFirst(4))
        return PublicSuffixList.isPublicSuffix(bare) ? host : bare
    }
}
