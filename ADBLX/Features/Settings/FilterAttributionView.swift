import SwiftUI

/// Filter List & Open Source Attribution View per PRD §10 licensing requirements.
struct FilterAttributionView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                headerSection
                filterListsSection
                openSourceSection
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .navigationTitle(LocalizedStringKey("about.licenses.navTitle"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Text("about.licenses.headerTitle")
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.primary)
            Text("about.licenses.headerSubtitle")
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
        }
    }

    private var filterListsSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("about.licenses.sectionFilterLists")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)

            VStack(spacing: DesignSpacing.gutter) {
                attributionCard(
                    title: "EasyList",
                    license: "GPLv3 / CC BY-SA 3.0",
                    authors: "EasyList Community (https://easylist.to)",
                    descriptionKey: "about.licenses.easylistDesc"
                )

                attributionCard(
                    title: "EasyPrivacy",
                    license: "GPLv3 / CC BY-SA 3.0",
                    authors: "EasyList Community (https://easylist.to)",
                    descriptionKey: "about.licenses.easyprivacyDesc"
                )

                attributionCard(
                    title: "Fanboy's Annoyance List",
                    license: "GPLv3 / CC BY 3.0",
                    authors: "Fanboy Community & Ryan Brown",
                    descriptionKey: "about.licenses.annoyancesDesc"
                )
            }
        }
    }

    private var openSourceSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("about.licenses.sectionNotice")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)

            Card {
                VStack(alignment: .leading, spacing: DesignSpacing.stackGap) {
                    Text("about.licenses.complianceStatement")
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
            }
        }
    }

    private func attributionCard(
        title: String,
        license: String,
        authors: String,
        descriptionKey: LocalizedStringKey
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DesignSpacing.stackGap) {
                HStack {
                    Text(title)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                    Spacer()
                    Text(license)
                        .font(DesignTypography.labelMono)
                        .foregroundStyle(DesignColors.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DesignColors.surfaceContainer)
                        .clipShape(Capsule())
                }

                Text(descriptionKey)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)

                Text(verbatim: "Maintained by: \(authors)")
                    .font(DesignTypography.labelMono)
                    .foregroundStyle(DesignColors.outline)
            }
        }
    }
}

#Preview {
    NavigationView {
        FilterAttributionView()
    }
}
