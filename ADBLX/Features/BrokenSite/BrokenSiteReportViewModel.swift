// ADBLX/Features/BrokenSite/BrokenSiteReportViewModel.swift
import Combine
import Foundation
import SwiftUI

@MainActor
public final class BrokenSiteReportViewModel: ObservableObject {
    @Published public var domainInput: String = ""
    @Published public var selectedCategory: BreakageCategory = .pageLayoutBroken
    @Published public var notesInput: String = ""
    @Published public var autoAllowlist: Bool = true
    @Published public var isSubmitting: Bool = false
    @Published public var submissionResult: ReportSubmissionResult? = nil
    @Published public var errorMessage: String? = nil

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

    public func submit() async {
        guard isDomainValid else {
            errorMessage = "Please enter a valid website domain."
            return
        }

        isSubmitting = true
        errorMessage = nil

        do {
            let result = try await reporter.submitReport(
                domain: domainInput,
                category: selectedCategory,
                notes: notesInput.isEmpty ? nil : notesInput,
                autoAllowlist: autoAllowlist
            )
            self.submissionResult = result
            self.isSubmitting = false
        } catch {
            self.errorMessage = error.localizedDescription
            self.isSubmitting = false
        }
    }

    public func reset() {
        domainInput = ""
        selectedCategory = .pageLayoutBroken
        notesInput = ""
        autoAllowlist = true
        isSubmitting = false
        submissionResult = nil
        errorMessage = nil
    }
}
