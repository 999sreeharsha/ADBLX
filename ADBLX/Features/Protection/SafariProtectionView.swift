// ADBLX/Features/Protection/SafariProtectionView.swift
import SwiftUI

struct SafariProtectionView: View {
    @State var viewModel: ProtectionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                Text("Safari Protection")
                    .font(DesignTypography.headlineLarge)
                    .foregroundStyle(DesignColors.onBackground)

                if let status = viewModel.status {
                    Card {
                        HStack {
                            Text("Safari Extension")
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            Spacer()
                            Text(status.isSafariExtensionEnabled ? "Enabled" : "Disabled")
                                .font(DesignTypography.labelMono)
                                .foregroundStyle(status.isSafariExtensionEnabled ? DesignColors.primary : DesignColors.error)
                        }
                    }

                    NavigationLink("Advanced Filter Lists") {
                        AdvancedFilterListsView(viewModel: viewModel)
                    }
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.primary)

                    Card {
                        ForEach(Array(status.categories.enumerated()), id: \.element.id) { index, category in
                            ToggleRow(
                                title: category.name,
                                subtitle: "\(category.description) · \(category.ruleCount) rules",
                                isOn: Binding(
                                    get: { viewModel.status?.categories[index].isEnabled ?? false },
                                    set: { _ in
                                        Task { await viewModel.toggleCategory(category.id) }
                                    }
                                )
                            )
                            if index < status.categories.count - 1 {
                                Divider()
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
}

#Preview {
    SafariProtectionView(viewModel: ProtectionViewModel(service: MockProtectionService()))
}
