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
                    featureRow(
                        icon: "network.badge.shield.half.filled",
                        titleKey: "trial.feature.dns.title",
                        bodyKey: "trial.feature.dns.body"
                    )
                    Divider()
                    featureRow(
                        icon: "play.rectangle.fill",
                        titleKey: "trial.feature.safari.title",
                        bodyKey: "trial.feature.safari.body"
                    )
                    Divider()
                    featureRow(
                        icon: "hand.raised.slash.fill",
                        titleKey: "trial.feature.tracking.title",
                        bodyKey: "trial.feature.tracking.body"
                    )
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
