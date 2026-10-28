// ADBLX/Features/Settings/AboutView.swift
import SwiftUI

struct AboutView: View {
    let viewModel = AboutViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                identitySection
                connectSection
                legalSection
                footer
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
    }

    private var identitySection: some View {
        VStack(spacing: DesignSpacing.stackGap) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignShape.cardCornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [DesignColors.primary, DesignColors.secondary],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)
                Image(systemName: "shield.checkered")
                    .font(.system(size: 40))
                    .foregroundStyle(DesignColors.onPrimary)
            }
            Text("about.title.app")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.primary)
            Text("about.tagline")
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
            Text(viewModel.versionDisplay)
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .padding(.horizontal, DesignSpacing.gutter)
                .padding(.vertical, DesignSpacing.base)
                .background(DesignColors.surfaceContainer)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
    }

    private var connectSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("about.section.connect")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .textCase(.uppercase)

            Card {
                Link(destination: URL(string: "https://adblx.app")!) {
                    HStack {
                        Image(systemName: "globe")
                            .foregroundStyle(DesignColors.primary)
                            .frame(width: 24)
                        Text("about.link.website")
                            .font(DesignTypography.bodyLarge)
                            .foregroundStyle(DesignColors.onSurface)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(DesignColors.outline)
                    }
                }
            }
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("about.section.legal")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .textCase(.uppercase)

            Card {
                VStack(spacing: 0) {
                    NavigationLink(destination: FilterAttributionView()) {
                        SettingsRow(titleKey: "about.row.licenses", systemImage: "doc.text.fill")
                    }
                    Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    Link(destination: URL(string: "https://adblx.app/privacy")!) {
                        SettingsRow(titleKey: "about.link.privacyPolicy", systemImage: "hand.raised.fill")
                    }
                    Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    Link(destination: URL(string: "https://adblx.app/terms")!) {
                        SettingsRow(titleKey: "about.link.termsOfService", systemImage: "doc.plaintext.fill")
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text("about.footer.copyright")
            .font(DesignTypography.bodySmall)
            .foregroundStyle(DesignColors.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.top, DesignSpacing.gutter)
    }
}

#Preview {
    AboutView()
}
