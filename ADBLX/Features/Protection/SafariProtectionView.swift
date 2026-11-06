// ADBLX/Features/Protection/SafariProtectionView.swift
import SwiftUI

struct SafariProtectionView: View {
    @State var viewModel: ProtectionViewModel
    let updateCoordinator: UpdateCoordinator
    let subscriptionService: SubscriptionService
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingUpdateProgress = false
    @State private var isShowingBrokenSiteReport = false

    init(
        viewModel: ProtectionViewModel,
        updateCoordinator: UpdateCoordinator,
        subscriptionService: SubscriptionService = AppCompositionRoot.makeSubscriptionService()
    ) {
        self._viewModel = State(initialValue: viewModel)
        self.updateCoordinator = updateCoordinator
        self.subscriptionService = subscriptionService
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                header

                if let status = viewModel.status {
                    heroCard
                    categoryGrid(for: status)
                    configurationList
                    premiumUpsell
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.refreshProtectionStatus(reason: .initialLoad) }
        .refreshable { await viewModel.refreshProtectionStatus(reason: .pullToRefresh) }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await viewModel.refreshProtectionStatus(reason: .foreground) }
            }
        }
        .sheet(isPresented: $isShowingUpdateProgress) {
            UpdateProgressSheet(model: UpdateProgressModel(), coordinator: updateCoordinator)
        }
        .sheet(isPresented: $isShowingBrokenSiteReport) {
            BrokenSiteReportView(
                viewModel: BrokenSiteReportViewModel(
                    reporter: AppCompositionRoot.makeBrokenSiteReporter(store: AppCompositionRoot.makeFilterStore())
                )
            )
        }
        .alert(
            Text("protection.settingsAlert.title"),
            isPresented: $viewModel.showSettingsPrompt,
            presenting: viewModel.pendingSettingsCategory
        ) { _ in
            Button("protection.settingsAlert.openSettings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("protection.settingsAlert.notNow", role: .cancel) { }
        } message: { category in
            Text(String(format: String(localized: "protection.settingsAlert.message"), category.name, category.name))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Text("protection.safari.title")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.onSurface)
            Text("protection.safari.subtitle")
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.onSurfaceVariant)
        }
    }

    private var masterBadgeLabel: LocalizedStringKey {
        switch viewModel.status?.masterState {
        case .active:
            return "protection.safari.badge.active"
        case .partiallyActive:
            return "protection.safari.badge.partiallyActive"
        case .disabledInSettings:
            return "protection.safari.badge.disabledInSettings"
        case .disabledByUser:
            return "protection.safari.badge.disabledByUser"
        case .unavailable, .none:
            return "protection.safari.badge.unavailable"
        }
    }

    private var masterBadgeColor: Color {
        switch viewModel.status?.masterState {
        case .active:
            return DesignColors.secondary
        case .partiallyActive:
            return Color.yellow
        case .disabledInSettings:
            return Color.orange
        case .disabledByUser:
            return DesignColors.onSurfaceVariant
        case .unavailable, .none:
            return DesignColors.outline
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Spacer()
            HStack(spacing: DesignSpacing.base) {
                Circle()
                    .fill(masterBadgeColor)
                    .frame(width: 8, height: 8)
                Text(masterBadgeLabel)
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(masterBadgeColor)
            }
            Text(String(format: String(localized: "protection.safari.stat.threatsBlocked"), 4281.formatted()))
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onSurface)
            Text("protection.safari.stat.period")
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSpacing.containerPadding)
        .frame(height: 176)
        .background(DesignColors.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.cardCornerRadius))
    }

    private func categoryGrid(for status: ProtectionStatus) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignSpacing.stackGap) {
            ForEach(Array(status.categories.enumerated()), id: \.element.id) { index, category in
                categoryTile(category, index: index)
            }
        }
    }

    private func categoryTile(_ category: ProtectionCategory, index: Int) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill(categoryIconColor(category.id).opacity(category.isEffectivelyActive ? 0.1 : 0.05))
                        .frame(width: 40, height: 40)
                    Image(systemName: categoryIcon(category.id))
                        .foregroundStyle(category.isEffectivelyActive ? categoryIconColor(category.id) : DesignColors.onSurfaceVariant)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.status?.categories[index].isEffectivelyActive ?? false },
                    set: { _ in Task { await viewModel.toggleCategory(category.id) } }
                ))
                .labelsHidden()
                .tint(DesignColors.primary)
            }
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(category.name)
                    .font(DesignTypography.headlineMedium)
                    .foregroundStyle(category.isEffectivelyActive ? DesignColors.onSurface : DesignColors.onSurfaceVariant)

                switch category.status {
                case .disabledInSettings:
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("protection.category.status.disabledInSettings")
                            .font(DesignTypography.labelCaps)
                    }
                    .foregroundStyle(Color.orange)
                case .unavailable:
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.caption2)
                        Text("protection.category.status.unavailable")
                            .font(DesignTypography.labelCaps)
                    }
                    .foregroundStyle(DesignColors.onSurfaceVariant)
                case .active, .disabledByUser:
                    EmptyView()
                }

                Text(category.description)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
                    .lineLimit(2)
            }
        }
        .padding(DesignSpacing.containerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignColors.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        .accessibilityElement(children: .combine)
    }

    private func categoryIcon(_ id: FilterCategoryID) -> String {
        switch id {
        case .ads: return "hand.raised.slash.fill"
        case .privacy: return "eye.slash.fill"
        case .annoyances: return "hand.tap.fill"
        case .regional: return "globe"
        }
    }

    private func categoryIconColor(_ id: FilterCategoryID) -> Color {
        switch id {
        case .ads: return DesignColors.primary
        case .privacy: return DesignColors.tertiary
        case .annoyances: return DesignColors.onSurface
        case .regional: return DesignColors.primary
        }
    }

    private var configurationList: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("protection.section.configuration")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)

            VStack(spacing: 0) {
                let rows = ProtectionConfigurationRow.visible()
                ForEach(rows, id: \.self) { row in
                    configurationEntry(row)
                    if row != rows.last {
                        Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    }
                }
            }
            .background(DesignColors.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        }
    }

    @ViewBuilder
    private func configurationEntry(_ row: ProtectionConfigurationRow) -> some View {
        switch row {
        case .advancedFilterLists:
            NavigationLink {
                AdvancedFilterListsView(viewModel: viewModel)
            } label: {
                configurationRow(
                    icon: "line.3.horizontal.decrease.circle.fill",
                    iconColor: DesignColors.primary,
                    titleKey: "protection.row.advancedFilterLists",
                    detailKey: "protection.row.advancedFilterLists.detail"
                )
            }
        case .dnsProtection:
            NavigationLink {
                DNSProtectionView(subscriptionService: subscriptionService)
            } label: {
                configurationRow(
                    icon: "lock.shield.fill",
                    iconColor: DesignColors.tertiary,
                    titleKey: "protection.row.dnsProtection",
                    detailKey: "protection.row.dnsProtection.detail"
                )
            }
        case .speedOptimization:
            configurationRow(
                icon: "bolt.fill",
                iconColor: DesignColors.primary,
                titleKey: "protection.row.speedOptimization",
                detailKey: nil
            )
        case .brokenSiteReport:
            Button {
                isShowingBrokenSiteReport = true
            } label: {
                configurationRow(
                    icon: "exclamationmark.bubble.fill",
                    iconColor: DesignColors.secondary,
                    titleKey: "brokenSite.row.title",
                    detailKey: "brokenSite.row.detail"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func configurationRow(
        icon: String,
        iconColor: Color,
        titleKey: LocalizedStringKey,
        detailKey: LocalizedStringKey?
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            Text(titleKey)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
            Spacer()
            if let detailKey {
                Text(detailKey)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(DesignColors.outline)
        }
        .padding(DesignSpacing.containerPadding)
        .contentShape(Rectangle())
    }

    private var premiumUpsell: some View {
        HStack(spacing: DesignSpacing.containerPadding) {
            VStack(alignment: .leading, spacing: DesignSpacing.base) {
                Text("premium.badge.upsellLabel")
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.onPrimaryContainer.opacity(0.8))
                    .padding(.horizontal, DesignSpacing.gutter)
                    .padding(.vertical, DesignSpacing.base / 2)
                    .background(DesignColors.onPrimaryContainer.opacity(0.2))
                    .clipShape(Capsule())
                Text("premium.upsell.title")
                    .font(DesignTypography.headlineMedium)
                    .foregroundStyle(DesignColors.onPrimaryContainer)
                Text("premium.upsell.body")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onPrimaryContainer.opacity(0.8))
            }
            Spacer()
            NavigationLink("premium.action.upgrade") {
                PremiumView(viewModel: PremiumViewModel(service: subscriptionService))
            }
            .font(DesignTypography.bodyLarge)
            .fontWeight(.bold)
            .foregroundStyle(DesignColors.primaryContainer)
            .padding(.horizontal, DesignSpacing.containerPadding)
            .padding(.vertical, DesignSpacing.base * 2)
            .background(DesignColors.onPrimaryContainer)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius))
        }
        .padding(DesignSpacing.sectionGap)
        .background(
            LinearGradient(
                colors: [DesignColors.primaryContainer, DesignColors.tertiaryContainer],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 32))
    }
}

#Preview {
    let store = AppCompositionRoot.makeFilterStore()
    NavigationStack {
        SafariProtectionView(
            viewModel: ProtectionViewModel(service: MockProtectionService()),
            updateCoordinator: AppCompositionRoot.makeUpdateCoordinator(
                pipeline: AppCompositionRoot.makeFilterPipeline(store: store), store: store
            ),
            subscriptionService: MockSubscriptionService()
        )
    }
}

/// The rows of the Protection tab's configuration list, so the build flag decides what the view
/// draws and a test can check it with the flag off.
nonisolated enum ProtectionConfigurationRow: CaseIterable, Hashable, Sendable {
    case advancedFilterLists
    case dnsProtection
    case speedOptimization
    case brokenSiteReport

    static func visible(dnsEnabled: Bool = BuildFeatures.dnsProtection) -> [ProtectionConfigurationRow] {
        allCases.filter { dnsEnabled || $0 != .dnsProtection }
    }
}
