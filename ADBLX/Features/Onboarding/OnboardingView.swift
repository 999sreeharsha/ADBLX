// ADBLX/Features/Onboarding/OnboardingView.swift
import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                VStack(spacing: DesignSpacing.stackGap) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 56))
                        .foregroundStyle(DesignColors.primary)
                    Text("onboarding.title.app")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("onboarding.subtitle.tagline")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                Card {
                    featureRow(icon: "lock.shield.fill", titleKey: "onboarding.feature.privacy.title", bodyKey: "onboarding.feature.privacy.body")
                    Divider()
                    featureRow(icon: "bolt.fill", titleKey: "onboarding.feature.speed.title", bodyKey: "onboarding.feature.speed.body")
                    Divider()
                    featureRow(icon: "checkmark.seal.fill", titleKey: "onboarding.feature.simplicity.title", bodyKey: "onboarding.feature.simplicity.body")
                }

                VStack(alignment: .leading, spacing: DesignSpacing.stackGap) {
                    Text("onboarding.section.activation")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("onboarding.instruction.enable")
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                    Card {
                        stepRow(number: 1, textKey: "onboarding.step.openSettings")
                        Divider()
                        stepRow(number: 2, textKey: "onboarding.step.tapExtensions")
                        Divider()
                        stepRow(number: 3, textKey: "onboarding.step.turnOn")
                    }
                }

                Card {
                    HStack(alignment: .top, spacing: DesignSpacing.gutter) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(DesignColors.secondary)
                        VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                            Text("onboarding.section.staySecure.title")
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            Text("onboarding.section.staySecure.body")
                                .font(DesignTypography.bodySmall)
                                .foregroundStyle(DesignColors.onSurfaceVariant)
                        }
                    }
                }

                VStack(spacing: DesignSpacing.stackGap) {
                    PrimaryButton(titleKey: "onboarding.button.getStarted", action: onFinish)
                    Button("onboarding.button.skip", action: onFinish)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
    }

    private func featureRow(icon: String, titleKey: LocalizedStringKey, bodyKey: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.gutter) {
            Image(systemName: icon)
                .foregroundStyle(DesignColors.primary)
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

    private func stepRow(number: Int, textKey: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.gutter) {
            Text(number, format: .number)
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.onPrimary)
                .frame(width: 24, height: 24)
                .background(DesignColors.primary)
                .clipShape(Circle())
            Text(textKey)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
