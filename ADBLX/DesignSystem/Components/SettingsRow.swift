// ADBLX/DesignSystem/Components/SettingsRow.swift
import SwiftUI

/// A navigation-style settings list row: icon, title, disclosure chevron.
struct SettingsRow: View {
    let titleKey: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(DesignColors.primary)
                .frame(width: 24)
            Text(titleKey)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(DesignColors.outline)
        }
        .padding(.vertical, DesignSpacing.gutter)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    SettingsRow(titleKey: "settings.row.about", systemImage: "info.circle.fill")
        .padding()
}
