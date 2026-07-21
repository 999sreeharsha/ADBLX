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
                    ForEach(FilterCategoryID.allCasesForDisplay, id: \.self) { category in
                        let listsInCategory = lists.filter { $0.category == category }
                        if !listsInCategory.isEmpty {
                            categorySection(title: category.displayName, lists: listsInCategory)
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
            Text("Filter Lists")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.onSurface)
            Text("Customize your blocking experience by enabling specialized community-maintained lists.")
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.onSurfaceVariant)
        }
    }

    private func categorySection(title: String, lists: [FilterListEntry]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text(title)
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
        .accessibilityLabel(list.isPremium ? "\(list.name), premium" : list.name)
        .accessibilityValue(list.isEnabled ? "On" : "Off")
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
                    Text("Apply Changes")
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
    static let allCasesForDisplay: [FilterCategoryID] = [.ads, .privacy, .annoyances, .regional]

    var displayName: String {
        switch self {
        case .ads: return "Ads"
        case .privacy: return "Privacy"
        case .annoyances: return "Annoyances"
        case .regional: return "Regional"
        }
    }
}

#Preview {
    AdvancedFilterListsView(viewModel: ProtectionViewModel(service: MockProtectionService()))
}
