// ADBLX/Features/Settings/AboutView.swift
import SwiftUI

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                VStack(spacing: DesignSpacing.stackGap) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 48))
                        .foregroundStyle(DesignColors.primary)
                    Text("about.title.app")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("about.version.label")
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity)

                Card {
                    Text("about.privacy.statement")
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                }

                Card {
                    Link("about.link.privacyPolicy", destination: URL(string: "https://adblx.app/privacy")!)
                        .font(DesignTypography.bodyLarge)
                    Divider()
                    Link("about.link.termsOfService", destination: URL(string: "https://adblx.app/terms")!)
                        .font(DesignTypography.bodyLarge)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
    }
}

#Preview {
    AboutView()
}
