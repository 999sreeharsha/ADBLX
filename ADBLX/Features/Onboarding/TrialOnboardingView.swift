// ADBLX/Features/Onboarding/TrialOnboardingView.swift
import SwiftUI

public struct TrialOnboardingView: View {
    @State private var viewModel: TrialOnboardingViewModel

    public init(viewModel: TrialOnboardingViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                // Header
                VStack(spacing: DesignSpacing.stackGap) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(DesignColors.primary)
                    Text("trial.onboarding.title")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                        .multilineTextAlignment(.center)
                    Text("trial.onboarding.subtitle")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                // Feature Highlights Card
                Card {
                    ForEach(TrialHighlight.visible(), id: \.self) { highlight in
                        if highlight != TrialHighlight.visible().first { Divider() }
                        featureRow(icon: highlight.icon, titleKey: highlight.titleKey, bodyKey: highlight.bodyKey)
                    }
                }

                // Notification & Transparency Note
                Card {
                    HStack(alignment: .top, spacing: DesignSpacing.gutter) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(DesignColors.secondary)
                        VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                            Text("trial.notice.noCommitment.title")
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            Text("trial.notice.noCommitment.body")
                                .font(DesignTypography.bodySmall)
                                .foregroundStyle(DesignColors.onSurfaceVariant)
                        }
                    }
                }

                // Action Buttons
                VStack(spacing: DesignSpacing.stackGap) {
                    PrimaryButton(titleKey: "trial.button.startTrial") {
                        Task {
                            await viewModel.startFreeTrial()
                        }
                    }
                    .disabled(viewModel.isActivating)

                    Button("trial.button.continueFree") {
                        viewModel.continueWithFree()
                    }
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
                    .disabled(viewModel.isActivating)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
    }

    private func featureRow(
        icon: String,
        titleKey: LocalizedStringKey,
        bodyKey: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.gutter) {
            Image(systemName: icon)
                .foregroundStyle(DesignColors.primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(titleKey)
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(bodyKey)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row of the onboarding feature card.
nonisolated enum TrialHighlight: CaseIterable, Equatable, Sendable {
    case dns
    case safari
    case tracking

    static func visible(dnsEnabled: Bool = BuildFeatures.dnsProtection) -> [TrialHighlight] {
        allCases.filter { dnsEnabled || $0 != .dns }
    }

    var icon: String {
        switch self {
        case .dns: return "network.badge.shield.half.filled"
        case .safari: return "play.rectangle.fill"
        case .tracking: return "hand.raised.slash.fill"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .dns: return "trial.feature.dns.title"
        case .safari: return "trial.feature.safari.title"
        case .tracking: return "trial.feature.tracking.title"
        }
    }

    var bodyKey: LocalizedStringKey {
        switch self {
        case .dns: return "trial.feature.dns.body"
        case .safari: return "trial.feature.safari.body"
        case .tracking: return "trial.feature.tracking.body"
        }
    }
}
