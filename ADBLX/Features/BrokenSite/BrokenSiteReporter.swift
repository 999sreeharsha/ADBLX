// ADBLX/Features/BrokenSite/BrokenSiteReporter.swift
import Foundation

/// Protocol for submitting privacy-preserving broken site reports and triggering instant allowlisting.
public protocol BrokenSiteReporting: Sendable {
    func sanitizeDomain(_ input: String) throws -> String
    func submitReport(
        domain: String,
        category: BreakageCategory,
        notes: String?,
        autoAllowlist: Bool
    ) async throws -> ReportSubmissionResult
}

/// Actor implementing broken site reporting with strict domain sanitization,
/// App Group allowlist integration, and network submission.
actor RealBrokenSiteReporter: BrokenSiteReporting {
    private let allowlistStore: AllowlistStore
    private let manifestStore: ManifestStore?
    private let dnsSettingsStore: DNSProtectionSettingsStore?
    private let session: HTTPSession
    private let endpoint: URL

    init(
        allowlistStore: AllowlistStore,
        manifestStore: ManifestStore? = nil,
        dnsSettingsStore: DNSProtectionSettingsStore? = nil,
        session: HTTPSession = URLSession.shared,
        endpoint: URL = URL(string: "https://999sreeharsha.github.io/ADBLX/api/reports")!
    ) {
        self.allowlistStore = allowlistStore
        self.manifestStore = manifestStore
        self.dnsSettingsStore = dnsSettingsStore
        self.session = session
        self.endpoint = endpoint
    }

    /// Normalizes and extracts the privacy-preserving eTLD+1 domain from user input.
    public nonisolated func sanitizeDomain(_ input: String) throws -> String {
        try SafariDomainNormalizer.extractETLDPlusOne(input: input)
    }

    /// Submits a broken site report, optionally adding the domain to the app-wide AllowlistStore.
    public func submitReport(
        domain: String,
        category: BreakageCategory,
        notes: String? = nil,
        autoAllowlist: Bool = true
    ) async throws -> ReportSubmissionResult {
        let cleanDomain = try sanitizeDomain(domain)

        var didAllowlist = false
        if autoAllowlist {
            _ = try await allowlistStore.add(domain: cleanDomain)
            didAllowlist = true
        }

        let payload = await buildPayload(domain: cleanDomain, category: category, notes: notes)
        return await transmitPayload(payload, cleanDomain: cleanDomain, didAllowlist: didAllowlist)
    }

    private func buildPayload(
        domain: String,
        category: BreakageCategory,
        notes: String?
    ) async -> BrokenSiteReportPayload {
        var activeFilterVersions: [String: String] = [:]
        if let cached = try? await manifestStore?.load() {
            for entry in cached.manifest.entries {
                activeFilterVersions[entry.id] = entry.version
            }
        }

        let dnsSettings = dnsSettingsStore?.loadSettings()
        let isDNSEnabled = dnsSettings?.isEnabled ?? false
        let resolverDescription: String? = {
            guard let settings = dnsSettings else { return nil }
            switch settings.resolverOption {
            case .quad9Default:
                return "quad9"
            case .custom:
                return "custom_ipv4_ipv6"
            }
        }()

        let sanitizedNotes: String? = {
            guard let raw = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return String(raw.prefix(500))
        }()

        return BrokenSiteReportPayload(
            domain: domain,
            breakageCategory: category,
            notes: sanitizedNotes,
            timestamp: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            iosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            activeFilterVersions: activeFilterVersions,
            dnsProtectionEnabled: isDNSEnabled,
            upstreamResolver: resolverDescription
        )
    }

    private func transmitPayload(
        _ payload: BrokenSiteReportPayload,
        cleanDomain: String,
        didAllowlist: Bool
    ) async -> ReportSubmissionResult {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 10.0

            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                if didAllowlist {
                    return .allowlistedOnly(domain: cleanDomain, networkError: "HTTP \(statusCode)")
                }
                return .failed(reason: "Server returned HTTP \(statusCode)")
            }

            return .success(reportID: payload.reportID, domain: cleanDomain, allowlisted: didAllowlist)
        } catch {
            if didAllowlist {
                return .allowlistedOnly(domain: cleanDomain, networkError: error.localizedDescription)
            }
            return .failed(reason: error.localizedDescription)
        }
    }
}
