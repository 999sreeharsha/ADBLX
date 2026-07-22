// ADBLX/Features/Home/HomeView.swift
import SwiftUI

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var isShowingUpdateProgress = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                if let status = viewModel.status {
                    heroCard(for: status)
                    monitoringGrid(for: status)
                    quickControls
                    activityFeed(for: status.recentActivity)
                }
            }
            .padding(.horizontal, DesignSpacing.containerPadding)
            .padding(.top, DesignSpacing.sectionGap)
        }
        .background(DesignColors.background)
        .safeAreaInset(edge: .top) { topBar }
        .task { await viewModel.load() }
        .sheet(isPresented: $isShowingUpdateProgress) {
            UpdateProgressSheet(model: UpdateProgressModel())
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            HStack(spacing: DesignSpacing.gutter / 2) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(DesignColors.primary)
                Text("home.title.app")
                    .font(DesignTypography.headlineMedium)
                    .foregroundStyle(DesignColors.primary)
            }
            Spacer()
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .padding(.trailing, DesignSpacing.containerPadding)
        }
        .padding(.vertical, DesignSpacing.gutter)
        .background(.ultraThinMaterial)
    }

    private func heroCard(for status: HomeStatus) -> some View {
        VStack(spacing: DesignSpacing.sectionGap / 1.5) {
            ZStack {
                Circle()
                    .fill(DesignColors.secondary.opacity(0.1))
                    .strokeBorder(DesignColors.secondary.opacity(0.2), lineWidth: 1)
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(DesignColors.secondary)
            }

            VStack(spacing: DesignSpacing.base) {
                Text(status.isProtectionEnabled ? "home.status.active" : "home.status.inactive")
                    .font(DesignTypography.headlineLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(status.isProtectionEnabled
                     ? "home.status.enabledDetail"
                     : "home.status.disabledDetail")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: DesignSpacing.gutter) {
                pillBadge {
                    Circle()
                        .fill(DesignColors.secondary)
                        .frame(width: 8, height: 8)
                    Text("home.badge.secure")
                        .font(DesignTypography.labelCaps)
                        .foregroundStyle(DesignColors.secondary)
                }
                pillBadge {
                    Text("v4.2.0")
                        .font(DesignTypography.labelCaps)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
            }
        }
        .padding(DesignSpacing.sectionGap)
        .frame(maxWidth: .infinity)
        .background(DesignColors.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .overlay(
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private func pillBadge(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: DesignSpacing.base) {
            content()
        }
        .padding(.horizontal, DesignSpacing.gutter)
        .padding(.vertical, DesignSpacing.base * 2)
        .background(Color.white.opacity(0.05))
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func monitoringGrid(for status: HomeStatus) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("home.section.monitoring")
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.outlineVariant)
                .textCase(.uppercase)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignSpacing.gutter) {
                statTile(icon: "safari", labelKey: "home.stat.safari.label", value: String(localized: "home.stat.safari.value"), detail: String(format: String(localized: "home.stat.safari.detail"), status.blockedPercentage.formatted(.number.precision(.fractionLength(1)))), detailColor: DesignColors.secondary, iconColor: DesignColors.primary)
                statTile(icon: "network", labelKey: "home.stat.dns.label", value: status.dnsProviderName, detail: String(localized: "home.stat.dns.detail"), detailColor: DesignColors.onSurfaceVariant, iconColor: DesignColors.tertiary)
                statTile(icon: "arrow.triangle.2.circlepath", labelKey: "home.stat.lastUpdate.label", value: status.lastUpdateDescription, detail: nil, detailColor: DesignColors.onSurfaceVariant, iconColor: .orange)
                statTile(icon: "list.bullet.rectangle", labelKey: "home.stat.rules.label", value: status.ruleCount.formatted(), detail: nil, detailColor: DesignColors.onSurfaceVariant, iconColor: DesignColors.secondary)
            }
        }
    }

    private func statTile(icon: String, labelKey: LocalizedStringKey, value: String, detail: String?, detailColor: Color, iconColor: Color) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            HStack(spacing: DesignSpacing.base) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(labelKey)
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.outlineVariant)
            }
            Text(value)
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onSurface)
            if let detail {
                Text(detail)
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(detailColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSpacing.containerPadding)
        .background(DesignColors.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        .overlay(
            RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("home.section.quickControl")
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.outlineVariant)
                .textCase(.uppercase)

            Button {
                isShowingUpdateProgress = true
            } label: {
                HStack {
                    Label("home.action.updateFilters", systemImage: "arrow.triangle.2.circlepath")
                        .font(DesignTypography.bodyLarge)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .opacity(0.5)
                }
                .foregroundStyle(DesignColors.onPrimary)
                .padding(DesignSpacing.containerPadding)
                .background(DesignColors.primaryContainer)
                .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            }

            Button {
                Task { await viewModel.load() }
            } label: {
                HStack {
                    Label("home.action.reloadSafari", systemImage: "arrow.clockwise")
                        .font(DesignTypography.bodyLarge)
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                        .opacity(0.3)
                }
                .foregroundStyle(DesignColors.onSurface)
                .padding(DesignSpacing.containerPadding)
                .background(DesignColors.surfaceContainerLowest)
                .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
            }
        }
    }

    private func activityFeed(for entries: [HomeActivityEntry]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("home.section.recentActivity")
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.outlineVariant)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    activityRow(entry)
                    if index < entries.count - 1 {
                        Divider().overlay(Color.white.opacity(0.05))
                    }
                }
            }
            .background(DesignColors.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            .overlay(
                RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
            )
        }
    }

    private func activityRow(_ entry: HomeActivityEntry) -> some View {
        HStack(spacing: DesignSpacing.containerPadding) {
            ZStack {
                Circle()
                    .fill(activityColor(for: entry.kind).opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: activityIcon(for: entry.kind))
                    .font(.caption)
                    .foregroundStyle(activityColor(for: entry.kind))
            }
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(entry.title)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurface)
                Text(entry.subtitle)
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.outlineVariant)
            }
            Spacer()
            Text(entry.timestamp)
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outlineVariant)
        }
        .padding(DesignSpacing.containerPadding)
        .accessibilityElement(children: .combine)
    }

    private func activityIcon(for kind: HomeActivityEntry.Kind) -> String {
        switch kind {
        case .trackerBlocked: return "hand.raised.slash.fill"
        case .filtersSynchronized: return "checkmark.circle.fill"
        case .protectionToggled: return "lock.shield.fill"
        }
    }

    private func activityColor(for kind: HomeActivityEntry.Kind) -> Color {
        switch kind {
        case .trackerBlocked: return DesignColors.error
        case .filtersSynchronized: return DesignColors.secondary
        case .protectionToggled: return DesignColors.primary
        }
    }
}

#Preview {
    HomeView(viewModel: HomeViewModel(service: MockHomeService()))
}
