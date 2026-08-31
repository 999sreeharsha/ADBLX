// ADBLX/Features/BrokenSite/BrokenSiteReportView.swift
import SwiftUI

public struct BrokenSiteReportView: View {
    @ObservedObject var viewModel: BrokenSiteReportViewModel
    @Environment(\.dismiss) private var dismiss

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

                        if let result = viewModel.submissionResult {
                            successState(result: result)
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

            // Instant allowlist toggle
            Toggle(isOn: $viewModel.autoAllowlist) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("brokenSite.allowlist.title")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(DesignColors.onSurface)
                    Text("brokenSite.allowlist.subtitle")
                        .font(.caption)
                        .foregroundColor(DesignColors.onSurfaceVariant)
                }
            }
            .tint(DesignColors.primaryContainer)
            .padding(12)
            .background(DesignColors.surfaceContainerHigh)
            .cornerRadius(10)

            // Optional notes
            VStack(alignment: .leading, spacing: 6) {
                Text("brokenSite.notes.label")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DesignColors.onSurfaceVariant)

                TextField("brokenSite.notes.placeholder", text: $viewModel.notesInput)
                    .padding(12)
                    .background(DesignColors.surfaceContainerHigh)
                    .cornerRadius(10)
                    .foregroundColor(DesignColors.onSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(DesignColors.outlineVariant, lineWidth: 1)
                    )
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

            if let error = viewModel.errorMessage {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundColor(DesignColors.error)
                    .padding(.horizontal, 4)
            }

            // Submit Button
            Button {
                Task {
                    await viewModel.submit()
                }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: DesignColors.onPrimary))
                    } else {
                        Image(systemName: "paperplane.fill")
                        Text(viewModel.autoAllowlist
                             ? "brokenSite.action.submitAndAllowlist"
                             : "brokenSite.action.submit")
                    }
                }
                .font(.headline)
                .foregroundColor(DesignColors.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(viewModel.isDomainValid
                            ? DesignColors.primaryContainer
                            : DesignColors.surfaceContainerHighest)
                .cornerRadius(12)
            }
            .disabled(!viewModel.isDomainValid || viewModel.isSubmitting)
            .padding(.top, 8)
        }
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

    private func successState(result: ReportSubmissionResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 54))
                .foregroundColor(DesignColors.secondary)
                .padding(.top, 20)

            VStack(spacing: 8) {
                Text("brokenSite.success.title")
                    .font(.title2.weight(.bold))
                    .foregroundColor(DesignColors.onBackground)

                switch result {
                case .success(_, let domain, let allowlisted):
                    if allowlisted {
                        Text(verbatim: "\(domain) has been added to your allowlist and will now load normally.")
                            .font(.subheadline)
                            .foregroundColor(DesignColors.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(verbatim: "Thank you for your report on \(domain). It will be reviewed by maintainers.")
                            .font(.subheadline)
                            .foregroundColor(DesignColors.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                    }
                case .allowlistedOnly(let domain, _):
                    Text(verbatim: "\(domain) has been added to your local allowlist. Network submission was queued.")
                        .font(.subheadline)
                        .foregroundColor(DesignColors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                case .failed(let reason):
                    Text(verbatim: "Could not submit: \(reason)")
                        .font(.subheadline)
                        .foregroundColor(DesignColors.error)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 16)

            Button("brokenSite.action.done") {
                dismiss()
            }
            .font(.headline)
            .foregroundColor(DesignColors.onPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(DesignColors.primaryContainer)
            .cornerRadius(12)
            .padding(.top, 12)
        }
        .padding(24)
        .background(DesignColors.surfaceContainerHigh)
        .cornerRadius(16)
    }
}
