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
                    Text("ADBLX")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("Version 1.0")
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity)

                Card {
                    Text("Zero data collection. Nothing about your browsing ever leaves your device.")
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                }

                Card {
                    Link("Privacy Policy", destination: URL(string: "https://adblx.app/privacy")!)
                        .font(DesignTypography.bodyLarge)
                    Divider()
                    Link("Terms of Service", destination: URL(string: "https://adblx.app/terms")!)
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
