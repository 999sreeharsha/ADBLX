// ADBLX/Features/BrokenSite/BrokenSiteReportViewModel.swift
import Combine
import Foundation
import SwiftUI

@MainActor
public final class BrokenSiteReportViewModel: ObservableObject {
    @Published public var domainInput: String = ""
    @Published public var selectedCategory: BreakageCategory = .pageLayoutBroken
    /// The report on show for review. Nothing has left the device while this is set.
    @Published public private(set) var report: BrokenSiteReport? = nil
    @Published public private(set) var delivery: BrokenSiteDelivery? = nil
    @Published public private(set) var allowlistedDomain: String? = nil
    @Published public private(set) var isWorking: Bool = false
    @Published public private(set) var errorMessage: String? = nil

    private let reporter: BrokenSiteReporting

    public init(
        reporter: BrokenSiteReporting,
        initialDomain: String = ""
    ) {
        self.reporter = reporter
        self.domainInput = initialDomain
    }

    public var isDomainValid: Bool {
        guard !domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        do {
            _ = try reporter.sanitizeDomain(domainInput)
            return true
        } catch {
            return false
        }
    }

    public func prepareReport() async {
        guard isDomainValid else {
            errorMessage = String(localized: "brokenSite.error.invalidDomain")
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            report = try await reporter.makeReport(domain: domainInput, category: selectedCategory)
        } catch {
            errorMessage = String(localized: "brokenSite.error.invalidDomain")
        }
    }

    public func cancelReview() {
        report = nil
    }

    /// Opens the user's mail app, or copies the report if none opens.
    public func send(open: (URL) async -> Bool, copy: (String) -> Void) async {
        guard let report else { return }
        if let url = report.mailURL(recipient: BrokenSiteReport.recipient), await open(url) {
            delivery = .mailOpened
        } else {
            copy(report.bodyText)
            delivery = .copiedToClipboard
        }
    }

    public func allowSite() async {
        guard isDomainValid else {
            errorMessage = String(localized: "brokenSite.error.invalidDomain")
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            allowlistedDomain = try await reporter.allowlist(domain: domainInput)
        } catch {
            errorMessage = String(localized: "brokenSite.error.allowFailed")
        }
    }
}
