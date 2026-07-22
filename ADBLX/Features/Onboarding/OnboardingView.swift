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
                    Text("ADBLX")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("Browse the web in total peace.")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                Card {
                    featureRow(icon: "lock.shield.fill", title: "Privacy First", body: "Blocks trackers before they ever load — nothing about your browsing leaves your device.")
                    Divider()
                    featureRow(icon: "bolt.fill", title: "Pure Speed", body: "Pages load faster with ads and trackers stripped out before rendering.")
                    Divider()
                    featureRow(icon: "checkmark.seal.fill", title: "Simplicity", body: "One toggle. No configuration required.")
                }

                VStack(alignment: .leading, spacing: DesignSpacing.stackGap) {
                    Text("Activation")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("To start blocking, please enable ADBLX in your Safari settings.")
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                    Card {
                        stepRow(number: 1, text: "Open Settings and tap Safari.")
                        Divider()
                        stepRow(number: 2, text: "Tap Extensions or Content Blockers.")
                        Divider()
                        stepRow(number: 3, text: "Turn on all ADBLX switches.")
                    }
                }

                Card {
                    HStack(alignment: .top, spacing: DesignSpacing.gutter) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(DesignColors.secondary)
                        VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                            Text("Stay Secure")
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            Text("We'll let you know when filter updates are ready, with a weekly security report.")
                                .font(DesignTypography.bodySmall)
                                .foregroundStyle(DesignColors.onSurfaceVariant)
                        }
                    }
                }

                VStack(spacing: DesignSpacing.stackGap) {
                    PrimaryButton(titleKey: "Get Started", action: onFinish)
                    Button("Skip for now", action: onFinish)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
    }

    private func featureRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.gutter) {
            Image(systemName: icon)
                .foregroundStyle(DesignColors.primary)
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(title)
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(body)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.gutter) {
            Text("\(number)")
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.onPrimary)
                .frame(width: 24, height: 24)
                .background(DesignColors.primary)
                .clipShape(Circle())
            Text(text)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
