// ADBLX/Features/Protection/AdvancedFilterListsView.swift
import SwiftUI

struct AdvancedFilterListsView: View {
    @State var viewModel: ProtectionViewModel
    @State private var isApplying = false

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
            .padding(.bottom, 96)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
        .safeAreaInset(edge: .bottom) { applyChangesButton }
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
                        Divider().overlay(Color.white.opacity(0.05))
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
            Toggle("", isOn: Binding(
                get: { list.isEnabled },
                set: { _ in Task { await viewModel.toggleFilterList(list.id) } }
            ))
            .labelsHidden()
            .tint(DesignColors.primaryContainer)
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
                    ProgressView().tint(.white)
                } else {
                    Text("protection.action.applyChanges")
                        .font(DesignTypography.bodyLarge)
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSpacing.gutter)
            .background(DesignColors.primaryContainer)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius))
        }
        .disabled(isApplying)
        .padding(DesignSpacing.containerPadding)
        .background(.ultraThinMaterial)
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
