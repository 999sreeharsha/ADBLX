// ADBLX/DesignSystem/Components/PremiumBadge.swift
import SwiftUI

struct PremiumBadge: View {
    var textKey: LocalizedStringKey = "premium.badge.label"

    var body: some View {
        Text(textKey)
            .font(DesignTypography.labelCaps)
            .foregroundStyle(DesignColors.onTertiary)
            .padding(.horizontal, DesignSpacing.gutter)
            .padding(.vertical, DesignSpacing.base / 2)
            .background(DesignColors.tertiary)
            .clipShape(Capsule())
    }
}

#Preview {
    PremiumBadge()
}
