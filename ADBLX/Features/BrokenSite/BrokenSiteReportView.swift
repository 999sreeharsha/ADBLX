// ADBLX/Features/BrokenSite/BrokenSiteReportView.swift
import SwiftUI
import UIKit

public struct BrokenSiteReportView: View {
    @ObservedObject var viewModel: BrokenSiteReportViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public init(viewModel: BrokenSiteReportViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                DesignColors.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection

                        if let report = viewModel.report {
                            reviewSection(report)
                        } else {
                            formSection
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(Text("brokenSite.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("brokenSite.action.close") {
                        dismiss()
                    }
                    .foregroundColor(DesignColors.primary)
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("brokenSite.header.title")
                .font(.title3.weight(.bold))
                .foregroundColor(DesignColors.onBackground)

            Text("brokenSite.header.subtitle")
                .font(.subheadline)
                .foregroundColor(DesignColors.onSurfaceVariant)
        }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Domain input section
            VStack(alignment: .leading, spacing: 6) {
                Text("brokenSite.domain.label")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DesignColors.onSurfaceVariant)

                HStack {
                    Image(systemName: "globe")
                        .foregroundColor(DesignColors.outline)

                    TextField("brokenSite.domain.placeholder", text: $viewModel.domainInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundColor(DesignColors.onSurface)
                }
                .padding(12)
                .background(DesignColors.surfaceContainerHigh)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(DesignColors.outlineVariant, lineWidth: 1)
                )
            }

            // Category picker section
            VStack(alignment: .leading, spacing: 6) {
                Text("brokenSite.category.label")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DesignColors.onSurfaceVariant)

                VStack(spacing: 8) {
                    ForEach(BreakageCategory.allCases) { category in
                        Button {
                            viewModel.selectedCategory = category
                        } label: {
                            categoryRow(for: category)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Privacy notice
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18))
                    .foregroundColor(DesignColors.secondary)

                Text("brokenSite.privacy.notice")
                    .font(.caption2)
                    .foregroundColor(DesignColors.onSurfaceVariant)
            }
            .padding(12)
            .background(DesignColors.surfaceContainerLow)
            .cornerRadius(10)

            errorText

            primaryButton(
                titleKey: "brokenSite.action.review",
                systemImage: "doc.text.magnifyingglass",
                isEnabled: viewModel.isDomainValid && !viewModel.isWorking
            ) {
                Task { await viewModel.prepareReport() }
            }
            .padding(.top, 8)

            allowSection
        }
    }

    /// Separate from reporting: a site is allowlisted only when the user taps this.
    private var allowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("brokenSite.allowlist.subtitle")
                .font(.caption)
                .foregroundColor(DesignColors.onSurfaceVariant)

            Button {
                Task { await viewModel.allowSite() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isWorking {
                        ProgressView()
                    }
                    Text("brokenSite.action.allow")
                }
                .font(.headline)
                .foregroundColor(DesignColors.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(DesignColors.surfaceContainerHigh)
                .cornerRadius(12)
            }
            .disabled(!viewModel.isDomainValid || viewModel.isWorking)

            if let domain = viewModel.allowlistedDomain {
                Text(verbatim: String(format: String(localized: "brokenSite.allowlist.done"), domain))
                    .font(.caption)
                    .foregroundColor(DesignColors.secondary)
            }
        }
    }

    private func reviewSection(_ report: BrokenSiteReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("brokenSite.review.title")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DesignColors.onSurface)

            Text(verbatim: report.bodyText)
                .font(.caption.monospaced())
                .foregroundColor(DesignColors.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(DesignColors.surfaceContainerHigh)
                .cornerRadius(10)
                .textSelection(.enabled)

            switch viewModel.delivery {
            case .mailOpened:
                deliveryMessage("brokenSite.delivery.mailOpened")
                doneButton
            case .copiedToClipboard:
                deliveryMessage("brokenSite.delivery.copied")
                doneButton
            case nil:
                Text("brokenSite.review.note")
                    .font(.caption)
                    .foregroundColor(DesignColors.onSurfaceVariant)

                primaryButton(titleKey: "brokenSite.action.sendMail", systemImage: "envelope.fill", isEnabled: true) {
                    Task {
                        await viewModel.send(
                            open: { url in
                                await withCheckedContinuation { continuation in
                                    openURL(url) { continuation.resume(returning: $0) }
                                }
                            },
                            copy: { UIPasteboard.general.string = $0 }
                        )
                    }
                }

                Button("brokenSite.action.back") {
                    viewModel.cancelReview()
                }
                .font(.headline)
                .foregroundColor(DesignColors.primary)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func deliveryMessage(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.subheadline)
            .foregroundColor(DesignColors.onSurfaceVariant)
    }

    private var doneButton: some View {
        primaryButton(titleKey: "brokenSite.action.done", systemImage: "checkmark", isEnabled: true) {
            dismiss()
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = viewModel.errorMessage {
            Text(verbatim: error)
                .font(.caption)
                .foregroundColor(DesignColors.error)
                .padding(.horizontal, 4)
        }
    }

    private func primaryButton(
        titleKey: LocalizedStringKey, systemImage: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(titleKey)
            }
            .font(.headline)
            .foregroundColor(DesignColors.onPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isEnabled ? DesignColors.primaryContainer : DesignColors.surfaceContainerHighest)
            .cornerRadius(12)
        }
        .disabled(!isEnabled)
    }

    private func categoryRow(for category: BreakageCategory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.iconName)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundColor(viewModel.selectedCategory == category ? DesignColors.primary : DesignColors.outline)

            Text(LocalizedStringKey(category.displayName))
                .font(.subheadline)
                .foregroundColor(DesignColors.onSurface)

            Spacer()

            if viewModel.selectedCategory == category {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(DesignColors.primary)
            }
        }
        .padding(12)
        .background(
            viewModel.selectedCategory == category
                ? DesignColors.primaryContainer.opacity(0.2)
                : DesignColors.surfaceContainerHigh
        )
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    viewModel.selectedCategory == category
                        ? DesignColors.primary
                        : DesignColors.outlineVariant,
                    lineWidth: 1
                )
        )
    }
}
