// ADBLX/Features/Premium/PremiumView.swift
import SwiftUI

struct PremiumView: View {
    @State var viewModel: PremiumViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                hero

                if let plans = viewModel.status?.plans {
                    pricingSection(plans: plans)
                }

                featuresSection
                comparisonSection

                if let error = viewModel.purchaseError {
                    Text(error.localizedDescription)
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.error)
                }

                actionButtons
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
    }

    private var hero: some View {
        VStack(spacing: DesignSpacing.gutter) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignShape.cardCornerRadius)
                    .fill(DesignColors.tertiary.opacity(0.1))
                    .strokeBorder(DesignColors.tertiary.opacity(0.3), lineWidth: 1)
                    .frame(width: 80, height: 80)
                Image(systemName: "crown.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(DesignColors.tertiary)
            }
            Text("Unlock Ultimate Privacy")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.tertiary)
                .multilineTextAlignment(.center)
            Text("Experience a faster, cleaner, and safer web without limits.")
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSpacing.sectionGap)
    }

    private func pricingSection(plans: [SubscriptionPlan]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("Select a Plan")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .textCase(.uppercase)

            ForEach(plans) { plan in
                planCard(plan, isBestValue: plan.id == "annual")
            }
        }
    }

    private func planCard(_ plan: SubscriptionPlan, isBestValue: Bool) -> some View {
        Button {
            Task { await viewModel.purchase(planID: plan.id) }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: DesignSpacing.containerPadding) {
                    ZStack {
                        Circle()
                            .fill((isBestValue ? DesignColors.tertiary : DesignColors.surfaceContainer).opacity(isBestValue ? 0.2 : 0.5))
                            .frame(width: 48, height: 48)
                        Image(systemName: isBestValue ? "calendar" : "infinity")
                            .foregroundStyle(isBestValue ? DesignColors.tertiary : DesignColors.outline)
                    }
                    VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                        Text(plan.name)
                            .font(DesignTypography.headlineMedium)
                            .foregroundStyle(DesignColors.primary)
                        Text(plan.billingPeriodDescription)
                            .font(DesignTypography.bodySmall)
                            .foregroundStyle(DesignColors.onSurfaceVariant)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: DesignSpacing.base / 2) {
                        Text(plan.priceDescription)
                            .font(DesignTypography.headlineMedium)
                            .foregroundStyle(isBestValue ? DesignColors.tertiary : DesignColors.onSurfaceVariant)
                        Text(isBestValue ? "per year" : "one-time")
                            .font(DesignTypography.labelCaps)
                            .foregroundStyle(DesignColors.onSurfaceVariant)
                    }
                }
                .padding(DesignSpacing.containerPadding)
                .background(.ultraThinMaterial)
                .background(isBestValue ? DesignColors.tertiary.opacity(0.05) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                        .strokeBorder(isBestValue ? DesignColors.tertiary.opacity(0.5) : DesignColors.outlineVariant.opacity(0.3), lineWidth: isBestValue ? 2 : 1)
                )

                if isBestValue {
                    Text("Best Value")
                        .font(DesignTypography.labelCaps)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSpacing.gutter)
                        .padding(.vertical, DesignSpacing.base / 2)
                        .background(DesignColors.tertiary)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: DesignShape.smallCornerRadius, topTrailingRadius: DesignShape.defaultCornerRadius * 2))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(plan.name), \(plan.priceDescription) \(plan.billingPeriodDescription)")
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("Premium Power")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .textCase(.uppercase)

            featureCard(icon: "network", iconColor: DesignColors.primary, title: "DNS Protection", description: "System-wide ad blocking via encrypted DNS queries. Blocks trackers in apps beyond the browser.")
            featureCard(icon: "arrow.triangle.2.circlepath", iconColor: DesignColors.tertiary, title: "Background Updates", description: "Blocklists stay fresh automatically. You never have to manually check for new tracker signatures.")
            featureCard(icon: "play.tv.fill", iconColor: DesignColors.secondary, title: "YouTube Safari Enhancements", description: "Native-like experience in Safari with no video ads, background play, and PiP support.")
        }
    }

    private func featureCard(icon: String, iconColor: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.containerPadding) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .padding(DesignSpacing.gutter / 1.5)
                .background(iconColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: DesignShape.smallCornerRadius * 2))
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(title)
                    .font(DesignTypography.bodyLarge)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignColors.primary)
                Text(description)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
        }
        .padding(DesignSpacing.containerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        .overlay(
            RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("Comparison")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                comparisonHeaderRow
                comparisonRow(feature: "Safari Blocking", freeIncluded: true, premiumIncluded: true)
                comparisonRow(feature: "DNS Protection", freeIncluded: false, premiumIncluded: true)
                comparisonRow(feature: "Auto Updates", freeIncluded: false, premiumIncluded: true)
                comparisonRow(feature: "Premium Themes", freeIncluded: false, premiumIncluded: true)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            .overlay(
                RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var comparisonHeaderRow: some View {
        HStack {
            Text("Feature")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
            Spacer()
            Text("Free")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .frame(width: 60)
            Text("Premium")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.tertiary)
                .frame(width: 60)
        }
        .padding(DesignSpacing.containerPadding)
        .background(DesignColors.surfaceContainerHigh.opacity(0.3))
    }

    private func comparisonRow(feature: String, freeIncluded: Bool, premiumIncluded: Bool) -> some View {
        HStack {
            Text(feature)
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.primary)
            Spacer()
            comparisonMark(included: freeIncluded, color: DesignColors.outline)
                .frame(width: 60)
            comparisonMark(included: premiumIncluded, color: DesignColors.tertiary)
                .frame(width: 60)
        }
        .padding(DesignSpacing.containerPadding)
        .overlay(alignment: .bottom) {
            Divider().overlay(DesignColors.outlineVariant.opacity(0.1))
        }
    }

    private func comparisonMark(included: Bool, color: Color) -> some View {
        Image(systemName: included ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(included ? color : DesignColors.outline)
    }

    private var actionButtons: some View {
        VStack(spacing: DesignSpacing.stackGap) {
            Button {
                if let plan = viewModel.status?.plans.first(where: { $0.id == "annual" }) {
                    Task { await viewModel.purchase(planID: plan.id) }
                }
            } label: {
                Text("Upgrade to Premium")
                    .font(DesignTypography.bodyLarge)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSpacing.containerPadding)
                    .background(DesignColors.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            }

            HStack(spacing: DesignSpacing.stackGap) {
                Button("Restore") {}
                    .frame(maxWidth: .infinity)
                Button("Manage") {}
                    .frame(maxWidth: .infinity)
            }
            .font(DesignTypography.bodyLarge)
            .fontWeight(.semibold)
            .foregroundStyle(DesignColors.onSurface)
            .padding(.vertical, DesignSpacing.containerPadding)
            .overlay(
                RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                    .strokeBorder(DesignColors.outline.opacity(0.3), lineWidth: 1)
            )

            Text("By subscribing, you agree to our Terms of Use and Privacy Policy. Subscriptions automatically renew unless canceled 24 hours before the end of the current period.")
                .font(.system(size: 11))
                .foregroundStyle(DesignColors.outline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSpacing.sectionGap)
                .padding(.top, DesignSpacing.base)
        }
        .padding(.top, DesignSpacing.gutter)
    }
}

#Preview {
    PremiumView(viewModel: PremiumViewModel(service: MockSubscriptionService()))
}
