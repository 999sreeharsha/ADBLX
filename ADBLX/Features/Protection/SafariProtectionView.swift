// ADBLX/Features/Protection/SafariProtectionView.swift
import SwiftUI

struct SafariProtectionView: View {
    @State var viewModel: ProtectionViewModel
    @State private var isShowingUpdateProgress = false

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

                    NavigationLink("DNS Protection") {
                        DNSProtectionView()
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

                    PrimaryButton(title: "Check for Updates") {
                        isShowingUpdateProgress = true
                    }
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
        .sheet(isPresented: $isShowingUpdateProgress) {
            UpdateProgressSheet(model: UpdateProgressModel())
        }
    }
}

#Preview {
    SafariProtectionView(viewModel: ProtectionViewModel(service: MockProtectionService()))
}
