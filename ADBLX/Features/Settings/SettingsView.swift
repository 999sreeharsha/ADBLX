// ADBLX/Features/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system
    @State private var newDomain = ""
    @State private var showBrokenSiteReport = false
    @Environment(PlanStateModel.self) private var planStateModel: PlanStateModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                Text("settings.title")
                    .font(DesignTypography.headlineLarge)
                    .foregroundStyle(DesignColors.onBackground)

                planRow

                generalSection

                if let snapshot = viewModel.snapshot {
                    Card {
                        HStack {
                            Text("settings.row.iCloudSync")
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            Spacer()
                            PremiumBadge()
                        }
                        Text(snapshot.iCloudSyncEnabled ? "settings.status.on" : "settings.status.off")
                            .font(DesignTypography.bodySmall)
                            .foregroundStyle(DesignColors.onSurfaceVariant)
                    }

                    Card {
                        Text("settings.section.allowlist")
                            .font(DesignTypography.headlineMedium)
                            .foregroundStyle(DesignColors.onBackground)
                        ForEach(snapshot.allowlist) { entry in
                            HStack {
                                Text(entry.domain)
                                    .font(DesignTypography.bodyLarge)
                                    .foregroundStyle(DesignColors.onSurface)
                                Spacer()
                                Button {
                                    Task { await viewModel.removeAllowlistEntry(id: entry.id) }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(DesignColors.error)
                                }
                                .disabled(viewModel.isApplyingAllowlistEdit)
                            }
                            .padding(.vertical, DesignSpacing.base)
                        }
                        HStack {
                            TextField("settings.placeholder.addDomain", text: $newDomain)
                                .font(DesignTypography.bodyLarge)
                            Button("settings.action.add") {
                                Task {
                                    await viewModel.addAllowlistEntry(domain: newDomain)
                                    newDomain = ""
                                }
                            }
                            .disabled(newDomain.isEmpty)
                        }
                        .disabled(viewModel.isApplyingAllowlistEdit)
                        if viewModel.isApplyingAllowlistEdit {
                            HStack(spacing: DesignSpacing.base) {
                                ProgressView()
                                Text("settings.allowlist.applying")
                                    .font(DesignTypography.bodySmall)
                                    .foregroundStyle(DesignColors.onSurfaceVariant)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }

                    Button {
                        showBrokenSiteReport = true
                    } label: {
                        Card {
                            SettingsRow(titleKey: "brokenSite.row.title", systemImage: "exclamationmark.bubble.fill")
                        }
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        AboutView()
                    } label: {
                        Card {
                            SettingsRow(titleKey: "settings.row.about", systemImage: "info.circle.fill")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .sheet(isPresented: $showBrokenSiteReport, onDismiss: { Task { await viewModel.load() } }) {
            BrokenSiteReportView(
                viewModel: BrokenSiteReportViewModel(
                    reporter: AppCompositionRoot.makeBrokenSiteReporter(store: AppCompositionRoot.makeFilterStore())
                )
            )
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
    }

    /// Top-of-screen "Plan" row. Shows nothing plan-specific until the model has resolved,
    /// so the first frame never flashes "Free" for a paying user.
    private var planRow: some View {
        Card {
            NavigationLink {
                PremiumView(viewModel: PremiumViewModel(service: AppCompositionRoot.makeSubscriptionService()))
            } label: {
                generalRow(
                    titleKey: "settings.row.plan",
                    systemImage: "crown.fill",
                    detail: Text(verbatim: planStateModel.flatMap { $0.isResolved ? PlanStateDisplay.planRowText(for: $0.state) : nil } ?? "")
                )
            }
            .buttonStyle(.plain)
            #if DEBUG
            Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
            NavigationLink {
                DeveloperDiagnosticsView()
            } label: {
                SettingsRow(titleKey: "settings.row.developer", systemImage: "hammer.fill")
            }
            .buttonStyle(.plain)
            #endif
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("settings.section.general")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .textCase(.uppercase)

            Card {
                VStack(spacing: 0) {
                    NavigationLink {
                        appearancePicker
                    } label: {
                        generalRow(
                            titleKey: "settings.row.appearance",
                            systemImage: "circle.lefthalf.filled",
                            detail: appearance.displayNameKey
                        )
                    }
                    Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    generalRow(
                        titleKey: "settings.row.language", systemImage: "character.bubble",
                        detail: Text(
                            Locale.current.localizedString(forIdentifier: Locale.current.identifier)
                                ?? Locale.current.identifier
                        )
                    )
                    Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    NavigationLink {
                        ComingSoonState(
                            title: "settings.row.notifications",
                            message: "settings.notifications.comingSoon.message"
                        )
                    } label: {
                        SettingsRow(titleKey: "settings.row.notifications", systemImage: "bell.fill")
                    }
                    Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    NavigationLink {
                        ComingSoonState(
                            title: "settings.row.safariHelp",
                            message: "settings.safariHelp.comingSoon.message"
                        )
                    } label: {
                        SettingsRow(titleKey: "settings.row.safariHelp", systemImage: "safari")
                    }
                }
            }
        }
    }

    private func generalRow(
        titleKey: LocalizedStringKey, systemImage: String, detail: LocalizedStringKey
    ) -> some View {
        generalRow(titleKey: titleKey, systemImage: systemImage, detail: Text(detail))
    }

    private func generalRow(titleKey: LocalizedStringKey, systemImage: String, detail: Text) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(DesignColors.primary)
                .frame(width: 24)
            Text(titleKey)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
            Spacer()
            detail
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(DesignColors.outline)
        }
        .padding(.vertical, DesignSpacing.gutter)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var appearancePicker: some View {
        List(AppearancePreference.allCases, id: \.self) { preference in
            Button {
                appearance = preference
            } label: {
                HStack {
                    Text(preference.displayNameKey)
                        .foregroundStyle(DesignColors.onSurface)
                    Spacer()
                    if preference == appearance {
                        Image(systemName: "checkmark")
                            .foregroundStyle(DesignColors.primary)
                    }
                }
            }
        }
        .navigationTitle(Text("settings.row.appearance"))
    }
}

#Preview {
    SettingsView(viewModel: SettingsViewModel(service: MockSettingsService()))
}
