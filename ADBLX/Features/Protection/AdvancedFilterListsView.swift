// ADBLX/Features/Protection/AdvancedFilterListsView.swift
import SwiftUI

struct AdvancedFilterListsView: View {
    @State var viewModel: ProtectionViewModel
    @State private var isApplying = false
    @State private var paywallFocus: PremiumFeature?
    @Environment(PlanStateModel.self) private var planStateModel: PlanStateModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                header

                if let lists = viewModel.status?.filterLists {
                    if lists.isEmpty {
                        emptyState
                    } else {
                        ForEach(FilterCategoryID.allCases, id: \.self) { category in
                            let listsInCategory = lists.filter { $0.category == category }
                            if !listsInCategory.isEmpty {
                                categorySection(titleKey: category.displayNameKey, lists: listsInCategory)
                            }
                        }
                    }
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
        .safeAreaBar(edge: .bottom) { applyChangesButton }
        .sheet(isPresented: Binding(get: { paywallFocus != nil }, set: { if !$0 { paywallFocus = nil } })) {
            NavigationStack {
                PremiumView(viewModel: PremiumViewModel(
                    service: AppCompositionRoot.makeSubscriptionService(), focus: paywallFocus
                ))
            }
        }
    }

    /// Unknown plan state (no model, or not yet resolved) leaves the toggle working, so a
    /// paying user is never shown the paywall by mistake; enforcement is not done here.
    private func lockedFeature(for list: FilterListEntry) -> PremiumFeature? {
        guard let model = planStateModel, model.isResolved else { return nil }
        return PremiumFeature.lockedFeature(for: list, isEntitled: model.state.isEntitled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Text("protection.filterLists.title")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.onSurface)
            Text("protection.filterLists.subtitle")
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.onSurfaceVariant)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSpacing.stackGap) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(DesignColors.onSurfaceVariant)
            Text("protection.filterLists.empty")
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSpacing.sectionGap)
    }

    private func categorySection(titleKey: LocalizedStringKey, lists: [FilterListEntry]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text(titleKey)
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(Array(lists.enumerated()), id: \.element.id) { index, list in
                    filterListRow(list)
                    if index < lists.count - 1 {
                        Divider().overlay(DesignColors.onSurface.opacity(0.05))
                    }
                }
            }
            .background(DesignColors.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius))
        }
    }

    private func filterListRow(_ list: FilterListEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                HStack(spacing: DesignSpacing.base) {
                    Text(list.name)
                        .font(DesignTypography.bodyLarge)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignColors.onSurface)
                    if list.isPremium {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(DesignColors.tertiary)
                    }
                }
                Text("v\(list.version)")
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.primary.opacity(0.6))
            }
            Spacer()
            if let feature = lockedFeature(for: list) {
                Button { paywallFocus = feature } label: {
                    Image(systemName: "lock.circle.fill")
                        .font(.title2)
                        .foregroundStyle(DesignColors.tertiary)
                }
                .accessibilityLabel(Text("premium.focus.label"))
            } else {
                Toggle("", isOn: Binding(
                    get: { list.isEnabled },
                    set: { _ in Task { await viewModel.toggleFilterList(list.id) } }
                ))
                .labelsHidden()
                .tint(DesignColors.primaryContainer)
            }
        }
        .padding(DesignSpacing.containerPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            list.isPremium
                ? Text(String(format: String(localized: "protection.filterList.accessibility.premiumSuffix"), list.name))
                : Text(list.name)
        )
        .accessibilityValue(list.isEnabled ? Text("accessibility.value.on") : Text("accessibility.value.off"))
    }

    private var applyChangesButton: some View {
        Button {
            isApplying = true
            Task {
                await viewModel.load()
                isApplying = false
            }
        } label: {
            HStack {
                if isApplying {
                    ProgressView()
                } else {
                    Text("protection.action.applyChanges")
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .applyChangesButtonStyle()
        .tint(DesignColors.primaryContainer)
        .controlSize(.large)
        .disabled(isApplying)
        .padding(.horizontal, DesignSpacing.containerPadding)
    }
}

private extension FilterCategoryID {
    var displayNameKey: LocalizedStringKey {
        switch self {
        case .ads: return "protection.category.ads"
        case .privacy: return "protection.category.privacy"
        case .annoyances: return "protection.category.annoyances"
        case .regional: return "protection.category.regional"
        }
    }
}

#Preview {
    AdvancedFilterListsView(viewModel: ProtectionViewModel(service: MockProtectionService()))
}

private extension View {
    /// `.glassProminent` is unavailable on visionOS, which has its own glass material.
    @ViewBuilder
    func applyChangesButtonStyle() -> some View {
        #if os(visionOS)
        buttonStyle(.borderedProminent)
        #else
        buttonStyle(.glassProminent)
        #endif
    }
}
