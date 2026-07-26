// ADBLX/Navigation/RootTabView.swift
import SwiftUI

struct RootTabView: View {
    let dependencies: AppCompositionRoot.UIDependencies
    @Binding var appearance: AppearancePreference

    var body: some View {
        TabView {
            ForEach(AppTab.allCases, id: \.self) { tab in
                placeholder(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
            }
        }
        .tint(DesignColors.primary)
    }

    @ViewBuilder
    private func placeholder(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView(viewModel: HomeViewModel(service: dependencies.homeService), updateCoordinator: dependencies.updateCoordinator)
        case .protection:
            NavigationStack {
                SafariProtectionView(
                    viewModel: ProtectionViewModel(service: dependencies.protectionService),
                    updateCoordinator: dependencies.updateCoordinator
                )
            }
        case .premium:
            NavigationStack {
                PremiumView(viewModel: PremiumViewModel(service: dependencies.subscriptionService))
            }
        case .settings:
            NavigationStack {
                SettingsView(viewModel: SettingsViewModel(service: dependencies.settingsService), appearance: $appearance)
            }
        }
    }
}

#Preview {
    let store = AppCompositionRoot.makeFilterStore()
    let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
    RootTabView(
        dependencies: AppCompositionRoot.makeUIDependencies(
            configuration: .mock,
            store: store,
            updateCoordinator: AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)
        ),
        appearance: .constant(.system)
    )
}
