// ADBLX/Features/Home/HomeView.swift
import SwiftUI

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var isShowingUpdateProgress = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                header

                if let status = viewModel.status {
                    statusCard(for: status)
                    PrimaryButton(title: "Reload Safari Blockers") {
                        isShowingUpdateProgress = true
                    }
                    activityFeed(for: status.recentActivity)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $isShowingUpdateProgress) {
            UpdateProgressSheet(model: UpdateProgressModel())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Text("ADBLX")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.onBackground)
            Text(viewModel.status?.isProtectionEnabled == true
                 ? "System-wide protection is enabled"
                 : "Protection is off")
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .accessibilityLabel(viewModel.status?.isProtectionEnabled == true
                    ? "System-wide protection is enabled"
                    : "Protection is off")
        }
    }

    private func statusCard(for status: HomeStatus) -> some View {
        Card {
            statusRow(label: "Safari", value: "Enabled")
            statusRow(label: "DNS", value: status.dnsProviderName)
            statusRow(label: "Last Update", value: status.lastUpdateDescription)
            statusRow(label: "Rules", value: "\(status.ruleCount)")
            statusRow(label: "Blocked", value: "\(String(format: "%.1f", status.blockedPercentage))%")
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.onSurfaceVariant)
            Spacer()
            Text(value)
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.onSurface)
        }
        .accessibilityElement(children: .combine)
    }

    private func activityFeed(for entries: [HomeActivityEntry]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.stackGap) {
            Text("Recent Activity")
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onBackground)
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                    Text(entry.title)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                    Text("\(entry.subtitle) · \(entry.timestamp)")
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

#Preview {
    HomeView(viewModel: HomeViewModel(service: MockHomeService()))
}
