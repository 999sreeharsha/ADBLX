// ADBLX/Navigation/RootTabView.swift
import SwiftUI

struct RootTabView: View {
    let dependencies: AppCompositionRoot.UIDependencies

    var body: some View {
        TabView {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage) {
                    placeholder(for: tab)
                }
            }
        }
        .tint(DesignColors.primary)
    }

    @ViewBuilder
    private func placeholder(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            NavigationStack {
                HomeView(
                    viewModel: HomeViewModel(service: dependencies.homeService),
                    planCard: HomePlanCardViewModel(
                        stateProvider: SystemContentBlockerStateProvider(),
                        extensionIdentifiers: AppCompositionRoot.extensionIdentifiers,
                        subscriptionService: dependencies.subscriptionService
                    ),
                    subscriptionService: dependencies.subscriptionService,
                    updateCoordinator: dependencies.updateCoordinator
                )
            }
        case .protection:
            NavigationStack {
                SafariProtectionView(
                    viewModel: ProtectionViewModel(service: dependencies.protectionService),
                    updateCoordinator: dependencies.updateCoordinator,
                    subscriptionService: dependencies.subscriptionService
                )
            }
        case .premium:
            NavigationStack {
                PremiumView(viewModel: PremiumViewModel(service: dependencies.subscriptionService))
            }
        case .settings:
            NavigationStack {
                SettingsView(viewModel: SettingsViewModel(service: dependencies.settingsService))
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
            pipeline: pipeline,
            updateCoordinator: AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)
        )
    )
}
