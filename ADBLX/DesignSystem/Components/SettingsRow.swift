// ADBLX/DesignSystem/Components/SettingsRow.swift
import SwiftUI

/// A navigation-style settings list row: icon, title, disclosure chevron.
struct SettingsRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(DesignColors.primary)
                .frame(width: 24)
            Text(title)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(DesignColors.outline)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    SettingsRow(title: "About", systemImage: "info.circle.fill")
        .padding()
}
