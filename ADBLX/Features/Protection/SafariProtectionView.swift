// ADBLX/Features/Protection/SafariProtectionView.swift
import SwiftUI

struct SafariProtectionView: View {
    @State var viewModel: ProtectionViewModel
    @State private var isShowingUpdateProgress = false

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
        .task { await viewModel.load() }
        .sheet(isPresented: $isShowingUpdateProgress) {
            UpdateProgressSheet(model: UpdateProgressModel())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Text("Safari Protection")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.onSurface)
            Text("Highly optimized content blocking for a faster, cleaner browsing experience on iOS.")
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.onSurfaceVariant)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Spacer()
            HStack(spacing: DesignSpacing.base) {
                Circle()
                    .fill(DesignColors.secondary)
                    .frame(width: 8, height: 8)
                Text("ACTIVE PROTECTION")
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.secondary)
            }
            Text("4,281 Threats Blocked")
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(.white)
            Text("Last 24 hours on Safari")
                .font(DesignTypography.bodySmall)
                .foregroundStyle(.white.opacity(0.6))
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
                        .fill(categoryIconColor(category.id).opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: categoryIcon(category.id))
                        .foregroundStyle(categoryIconColor(category.id))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.status?.categories[index].isEnabled ?? false },
                    set: { _ in Task { await viewModel.toggleCategory(category.id) } }
                ))
                .labelsHidden()
                .tint(DesignColors.primary)
            }
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(category.name)
                    .font(DesignTypography.headlineMedium)
                    .foregroundStyle(DesignColors.onSurface)
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
            Text("Configuration")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)

            VStack(spacing: 0) {
                NavigationLink {
                    AdvancedFilterListsView(viewModel: viewModel)
                } label: {
                    configurationRow(icon: "line.3.horizontal.decrease.circle.fill", iconColor: DesignColors.primary, title: "Advanced Filter Lists", detail: "4 Enabled")
                }
                Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                NavigationLink {
                    DNSProtectionView()
                } label: {
                    configurationRow(icon: "lock.shield.fill", iconColor: DesignColors.tertiary, title: "DNS Protection", detail: "Cloudflare")
                }
                Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                configurationRow(icon: "bolt.fill", iconColor: DesignColors.primary, title: "Speed Optimization", detail: nil)
            }
            .background(DesignColors.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        }
    }

    private func configurationRow(icon: String, iconColor: Color, title: String, detail: String?) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            Text(title)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
            Spacer()
            if let detail {
                Text(detail)
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
                Text("ADBLX PREMIUM")
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, DesignSpacing.gutter)
                    .padding(.vertical, DesignSpacing.base / 2)
                    .background(.white.opacity(0.2))
                    .clipShape(Capsule())
                Text("Unlock AI Blocking")
                    .font(DesignTypography.headlineMedium)
                    .foregroundStyle(.white)
                Text("Zero-day threat detection and custom domain firewalling.")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            NavigationLink("Upgrade") {
                PremiumView(viewModel: PremiumViewModel(service: MockSubscriptionService()))
            }
            .font(DesignTypography.bodyLarge)
            .fontWeight(.bold)
            .foregroundStyle(DesignColors.primaryContainer)
            .padding(.horizontal, DesignSpacing.containerPadding)
            .padding(.vertical, DesignSpacing.base * 2)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius))
        }
        .padding(DesignSpacing.sectionGap)
        .background(
            LinearGradient(colors: [DesignColors.primaryContainer, DesignColors.tertiaryContainer], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 32))
    }
}

#Preview {
    NavigationStack {
        SafariProtectionView(viewModel: ProtectionViewModel(service: MockProtectionService()))
    }
}
