// ADBLX/Features/Premium/PremiumView.swift
import SwiftUI

struct PremiumView: View {
    @State var viewModel: PremiumViewModel
    @Environment(PlanStateModel.self) private var planStateModel: PlanStateModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                planHeader

                if let focus = viewModel.focus {
                    focusBanner(focus)
                } else {
                    hero
                }

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

                if let outcome = viewModel.restoreOutcome {
                    Text(outcome == .restored ? "premium.restore.restored" : "premium.restore.nothing")
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }

                actionButtons
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
        .onChange(of: viewModel.status) { Task { await planStateModel?.refresh() } }
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
            Text("premium.hero.title")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.tertiary)
                .multilineTextAlignment(.center)
            Text("premium.hero.subtitle")
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
            Text("premium.section.selectPlan")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .textCase(.uppercase)

            ForEach(plans) { plan in
                planCard(plan, isBestValue: plan.id == "annual")
            }
        }
    }

    private func planIcon(for planID: String) -> String {
        switch planID {
        case "monthly": return "calendar.badge.clock"
        case "annual": return "calendar"
        case "lifetime": return "infinity"
        default: return "star.fill"
        }
    }

    private func planPeriodKey(for planID: String) -> LocalizedStringKey {
        switch planID {
        case "monthly": return "premium.plan.periodMonthly"
        case "annual": return "premium.plan.periodYearly"
        case "lifetime": return "premium.plan.periodOneTime"
        default: return ""
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
                        Image(systemName: planIcon(for: plan.id))
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
                        Text(planPeriodKey(for: plan.id))
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
                        .strokeBorder(
                            isBestValue ? DesignColors.tertiary.opacity(0.5) : DesignColors.outlineVariant.opacity(0.3),
                            lineWidth: isBestValue ? 2 : 1
                        )
                )

                if isBestValue {
                    Text("premium.badge.bestValue")
                        .font(DesignTypography.labelCaps)
                        .foregroundStyle(DesignColors.onTertiary)
                        .padding(.horizontal, DesignSpacing.gutter)
                        .padding(.vertical, DesignSpacing.base / 2)
                        .background(DesignColors.tertiary)
                        .clipShape(UnevenRoundedRectangle(
                            bottomLeadingRadius: DesignShape.smallCornerRadius,
                            topTrailingRadius: DesignShape.defaultCornerRadius * 2
                        ))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(plan.name), \(plan.priceDescription) \(plan.billingPeriodDescription)")
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("premium.section.power")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .textCase(.uppercase)

            ForEach(PremiumFeature.displayOrder(focus: viewModel.focus), id: \.self) { feature in
                featureCard(
                    icon: feature.icon, iconColor: featureColor(feature),
                    titleKey: feature.titleKey, descriptionKey: feature.descriptionKey,
                    isFocused: feature == viewModel.focus
                )
            }
        }
    }

    private func featureColor(_ feature: PremiumFeature) -> Color {
        switch feature {
        case .dnsProtection: return DesignColors.primary
        case .premiumFilterLists, .backgroundUpdates: return DesignColors.tertiary
        case .youtube: return DesignColors.secondary
        }
    }

    private func featureCard(
        icon: String, iconColor: Color, titleKey: LocalizedStringKey, descriptionKey: LocalizedStringKey,
        isFocused: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.containerPadding) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .padding(DesignSpacing.gutter / 1.5)
                .background(iconColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: DesignShape.smallCornerRadius * 2))
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(titleKey)
                    .font(DesignTypography.bodyLarge)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignColors.primary)
                Text(descriptionKey)
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
                .strokeBorder(
                    isFocused ? DesignColors.tertiary.opacity(0.5) : DesignColors.onSurface.opacity(0.08),
                    lineWidth: isFocused ? 2 : 1
                )
        )
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("premium.section.comparison")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                comparisonHeaderRow
                comparisonRow(featureKey: "premium.comparison.safariBlocking", freeIncluded: true, premiumIncluded: true)
                comparisonRow(featureKey: "premium.comparison.dnsProtection", freeIncluded: false, premiumIncluded: true)
                comparisonRow(featureKey: "premium.comparison.autoUpdates", freeIncluded: false, premiumIncluded: true)
                comparisonRow(featureKey: "premium.comparison.premiumThemes", freeIncluded: false, premiumIncluded: true)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            .overlay(
                RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                    .strokeBorder(DesignColors.onSurface.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var comparisonHeaderRow: some View {
        HStack {
            Text("premium.comparison.feature")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
            Spacer()
            Text("premium.comparison.free")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .frame(width: 60)
            Text("premium.comparison.premium")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.tertiary)
                .frame(width: 60)
        }
        .padding(DesignSpacing.containerPadding)
        .background(DesignColors.surfaceContainerHigh.opacity(0.3))
    }

    private func comparisonRow(featureKey: LocalizedStringKey, freeIncluded: Bool, premiumIncluded: Bool) -> some View {
        HStack {
            Text(featureKey)
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
                if let plan = viewModel.status?.plans.first(where: { $0.id == "annual" }) ?? viewModel.status?.plans.first {
                    Task { await viewModel.purchase(planID: plan.id) }
                }
            } label: {
                Text("premium.action.upgradeToPremium")
                    .font(DesignTypography.bodyLarge)
                    .fontWeight(.bold)
                    .foregroundStyle(DesignColors.onTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSpacing.containerPadding)
                    .background(DesignColors.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            }

            HStack(spacing: DesignSpacing.stackGap) {
                Button("premium.action.restore") {
                    Task { await viewModel.restore() }
                }
                    .disabled(viewModel.isLoading)
                    .frame(maxWidth: .infinity)
                Button("premium.action.manage") {}
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

            Text("premium.legal.subscriptionTerms")
                .font(.system(size: 11))
                .foregroundStyle(DesignColors.outline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSpacing.sectionGap)
                .padding(.top, DesignSpacing.base)
        }
        .padding(.top, DesignSpacing.gutter)
    }
}

// MARK: - Plan header and focus (Phase 4a)

extension PremiumView {
    /// Current plan, from the same `PlanState` as Settings and Home. Hidden until resolved so a
    /// paying user never sees a "free plan" flash.
    @ViewBuilder
    private var planHeader: some View {
        if let model = planStateModel, model.isResolved {
            HStack(spacing: DesignSpacing.gutter) {
                Image(systemName: model.state.isEntitled ? "crown.fill" : "hourglass")
                    .foregroundStyle(DesignColors.tertiary)
                Text(verbatim: PlanStateDisplay.premiumHeaderText(for: model.state))
                    .font(DesignTypography.bodyLarge)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignColors.onSurface)
                Spacer(minLength: 0)
            }
            .padding(DesignSpacing.containerPadding)
            .background(DesignColors.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            .accessibilityElement(children: .combine)
        }
    }

    /// Replaces the generic hero when a locked control opened the paywall.
    private func focusBanner(_ feature: PremiumFeature) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("premium.focus.label")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.tertiary)
                .textCase(.uppercase)
            HStack(alignment: .top, spacing: DesignSpacing.containerPadding) {
                Image(systemName: feature.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(DesignColors.tertiary)
                VStack(alignment: .leading, spacing: DesignSpacing.base) {
                    Text(feature.titleKey)
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onSurface)
                    Text(feature.descriptionKey)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSpacing.containerPadding)
        .background(DesignColors.tertiary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        .overlay(
            RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                .strokeBorder(DesignColors.tertiary.opacity(0.5), lineWidth: 2)
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    PremiumView(viewModel: PremiumViewModel(service: MockSubscriptionService()))
}
