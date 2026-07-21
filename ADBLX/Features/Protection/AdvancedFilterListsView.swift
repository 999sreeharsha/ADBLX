// ADBLX/Features/Protection/AdvancedFilterListsView.swift
import SwiftUI

struct AdvancedFilterListsView: View {
    @State var viewModel: ProtectionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                Text("Advanced Filter Lists")
                    .font(DesignTypography.headlineLarge)
                    .foregroundStyle(DesignColors.onBackground)

                if let lists = viewModel.status?.filterLists {
                    ForEach(FilterCategoryID.allCasesForDisplay, id: \.self) { category in
                        let listsInCategory = lists.filter { $0.category == category }
                        if !listsInCategory.isEmpty {
                            Card {
                                ForEach(Array(listsInCategory.enumerated()), id: \.element.id) { index, list in
                                    filterListRow(list)
                                    if index < listsInCategory.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
    }

    private func filterListRow(_ list: FilterListEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                HStack(spacing: DesignSpacing.base / 2) {
                    Text(list.name)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                    if list.isPremium {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(DesignColors.tertiary)
                    }
                }
                Text("v\(list.version)")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { list.isEnabled },
                set: { _ in Task { await viewModel.toggleFilterList(list.id) } }
            ))
            .labelsHidden()
            .tint(DesignColors.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(list.isPremium ? "\(list.name), premium" : list.name)
        .accessibilityValue(list.isEnabled ? "On" : "Off")
    }
}

private extension FilterCategoryID {
    static let allCasesForDisplay: [FilterCategoryID] = [.ads, .privacy, .annoyances, .regional]
}

#Preview {
    AdvancedFilterListsView(viewModel: ProtectionViewModel(service: MockProtectionService()))
}
