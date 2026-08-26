// ADBLX/Features/Premium/Trial/TrialExpiredDecisionView.swift
import SwiftUI

public struct TrialExpiredDecisionView: View {
    @State private var viewModel: TrialExpiredDecisionViewModel
    private let subscriptionService: SubscriptionService

    public init(
        viewModel: TrialExpiredDecisionViewModel,
        subscriptionService: SubscriptionService = AppCompositionRoot.makeSubscriptionService()
    ) {
        _viewModel = State(initialValue: viewModel)
        self.subscriptionService = subscriptionService
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                // Header
                VStack(spacing: DesignSpacing.stackGap) {
                    Image(systemName: "hourglass.bottomhalf.filled")
                        .font(.system(size: 56))
                        .foregroundStyle(DesignColors.tertiary)
                    Text("trial.expired.title")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                        .multilineTextAlignment(.center)
                    Text("trial.expired.subtitle")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                // What stays free vs what is premium
                Card {
                    VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
                        Text("trial.expired.includedFree.title")
                            .font(DesignTypography.bodyLarge)
                            .foregroundStyle(DesignColors.onSurface)

                        featureRow(
                            icon: "checkmark.circle.fill",
                            color: DesignColors.secondary,
                            title: "Core Safari Ad & Tracker Blocking",
                            detail: "Always active, on-device, and private."
                        )
                        Divider()
                        featureRow(
                            icon: "checkmark.circle.fill",
                            color: DesignColors.secondary,
                            title: "Regular Filter Updates",
                            detail: "Free filter rules update automatically."
                        )
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
                        Text("trial.expired.premiumFeatures.title")
                            .font(DesignTypography.bodyLarge)
                            .foregroundStyle(DesignColors.onSurface)

                        featureRow(
                            icon: "lock.fill",
                            color: DesignColors.outline,
                            title: "System-Wide DNS Protection",
                            detail: "Encrypted DNS filtering across all apps."
                        )
                        Divider()
                        featureRow(
                            icon: "lock.fill",
                            color: DesignColors.outline,
                            title: "Advanced Safari & YouTube Blocking",
                            detail: "Video ad protection and cosmetic filtering."
                        )
                    }
                }

                // 50/50 Equal Weight Action Buttons
                VStack(spacing: DesignSpacing.stackGap) {
                    PrimaryButton(titleKey: "trial.expired.button.viewPlans") {
                        viewModel.viewPremiumPlans()
                    }
                    .disabled(viewModel.isProcessing)

                    Button {
                        Task {
                            await viewModel.continueWithFree()
                        }
                    } label: {
                        Text("trial.expired.button.continueFree")
                            .font(DesignTypography.headlineMedium)
                            .foregroundStyle(DesignColors.onSurface)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignSpacing.gutter)
                            .background(DesignColors.surfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius))
                    }
                    .disabled(viewModel.isProcessing)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $viewModel.showPaywallSheet) {
            NavigationStack {
                PremiumView(viewModel: PremiumViewModel(service: subscriptionService))
            }
        }
    }

    private func featureRow(
        icon: String,
        color: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.gutter) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(title)
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(detail)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
