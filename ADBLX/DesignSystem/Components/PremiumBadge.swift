// ADBLX/DesignSystem/Components/PremiumBadge.swift
import SwiftUI

struct PremiumBadge: View {
    var text: String = "Premium"

    var body: some View {
        Text(text)
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
