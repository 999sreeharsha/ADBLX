import SwiftUI

/// The plan area at the top of Home: a chip, the trial-ending card, or the protection card.
/// It renders `HomePlanCardViewModel.presentation` and decides nothing itself.
struct HomePlanCardView: View {
    let viewModel: HomePlanCardViewModel
    let subscriptionService: SubscriptionService
    let plan: PlanState
    let isResolved: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingPremium = false

    var body: some View {
        content
            .task { await refresh() }
            .onChange(of: plan) { Task { await refresh() } }
            .onChange(of: isResolved) { Task { await refresh() } }
            // The user may have turned an extension on or off in Settings.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
            .sheet(isPresented: $isShowingPremium) {
                NavigationStack {
                    PremiumView(viewModel: PremiumViewModel(service: subscriptionService))
                }
            }
    }

    private func refresh() async {
        await viewModel.refresh(plan: plan, isResolved: isResolved)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.presentation {
        case .unresolved:
            placeholder
        case .hidden:
            EmptyView()
        case .trialChip(let days):
            chip(HomePlanCardStrings.trialChip(daysRemaining: days))
        case .trialEndingCard(let endsAt):
            trialEndingCard(endsAt: endsAt)
        case .protectionCard:
            protectionCard(title: "home.plan.protection.title", subtitle: nil)
        case .freePlanCard:
            protectionCard(title: "home.plan.free.title", subtitle: "home.plan.free.subtitle")
        case .freeChip:
            chip(String(localized: "home.plan.chip.free"))
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
            .fill(DesignColors.onSurface.opacity(0.05))
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityElement()
            .accessibilityLabel(Text("home.plan.unresolved"))
    }

    private func chip(_ text: String) -> some View {
        Button { isShowingPremium = true } label: {
            HStack(spacing: DesignSpacing.base) {
                Image(systemName: "sparkles")
                Text(text)
                    .font(DesignTypography.bodySmall)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").opacity(0.4).accessibilityHidden(true)
            }
            .foregroundStyle(DesignColors.primary)
            .padding(DesignSpacing.containerPadding)
            .background(DesignColors.surfaceContainerLowest)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(DesignColors.onSurface.opacity(0.1), lineWidth: 1))
        }
        .accessibilityHint(Text("home.plan.seePlans"))
    }

    private func trialEndingCard(endsAt: Date) -> some View {
        card {
            Text(String(
                format: String(localized: "home.plan.trialEnding.title"),
                endsAt.formatted(date: .long, time: .omitted)
            ))
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onSurface)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: DesignSpacing.gutter) {
                Button { isShowingPremium = true } label: {
                    Text("home.plan.seePlans")
                        .font(DesignTypography.bodyLarge).fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(DesignSpacing.gutter)
                        .foregroundStyle(DesignColors.onPrimary)
                        .background(DesignColors.primary)
                        .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
                }
                Button { viewModel.dismiss(plan: plan) } label: {
                    Text("home.plan.later")
                        .font(DesignTypography.bodyLarge)
                        .frame(maxWidth: .infinity)
                        .padding(DesignSpacing.gutter)
                        .foregroundStyle(DesignColors.onSurface)
                }
            }
        }
    }

    private func protectionCard(title: LocalizedStringKey, subtitle: LocalizedStringKey?) -> some View {
        card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                    Text(title)
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onSurface)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(DesignTypography.bodySmall)
                            .foregroundStyle(DesignColors.onSurfaceVariant)
                    }
                }
                Spacer()
                Button { viewModel.dismiss(plan: plan) } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                        .padding(DesignSpacing.base)
                }
                .accessibilityLabel(Text("home.plan.dismiss"))
            }
            if let breakdown = viewModel.breakdown {
                section("home.plan.protection.stillOn", items: breakdown.stillOn, isOn: true)
                section("home.plan.protection.turnedOff", items: breakdown.turnedOff, isOn: false)
            }
            premiumButton
        }
    }

    private func section(_ titleKey: LocalizedStringKey, items: [ProtectionBreakdown.Item], isOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Text(titleKey)
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.outlineVariant)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            ForEach(items, id: \.titleKey) { item in
                HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.base) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(isOn ? DesignColors.secondary : DesignColors.outlineVariant)
                        .accessibilityHidden(true)
                    Text(item.title)
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(isOn ? DesignColors.onSurface : DesignColors.onSurfaceVariant)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(isOn ? "home.plan.status.on" : "home.plan.status.off"))
            }
        }
    }

    private var premiumButton: some View {
        Button { isShowingPremium = true } label: {
            VStack(spacing: DesignSpacing.base / 2) {
                Text("home.plan.getPremium")
                    .font(DesignTypography.bodyLarge).fontWeight(.semibold)
                if let line = viewModel.prices.summaryLine {
                    Text(line).font(DesignTypography.labelCaps)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(DesignSpacing.gutter)
            .foregroundStyle(DesignColors.onPrimary)
            .background(DesignColors.primary)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter, content: content)
            .padding(DesignSpacing.containerPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignColors.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            .overlay(
                RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                    .strokeBorder(DesignColors.onSurface.opacity(0.05), lineWidth: 1)
            )
    }
}
