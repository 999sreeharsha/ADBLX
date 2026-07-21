// ADBLX/DesignSystem/Components/ToggleRow.swift
import SwiftUI

/// A titled, subtitled row ending in a Toggle. Stitch theme: switches use full
/// pill-shaping and the Privacy Purple "on" tint with a spring-animated transition.
struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(title)
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(subtitle)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(DesignColors.primary)
                .animation(.spring, value: isOn)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

#Preview {
    ToggleRow(title: "Ads", subtitle: "Blocks display and video ads", isOn: .constant(true))
        .padding()
}
