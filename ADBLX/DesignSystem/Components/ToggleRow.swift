// ADBLX/DesignSystem/Components/ToggleRow.swift
import SwiftUI

/// A titled, subtitled row ending in a Toggle. Stitch theme: switches use full
/// pill-shaping and the Privacy Purple "on" tint with a spring-animated transition.
struct ToggleRow: View {
    let titleKey: LocalizedStringKey
    let subtitleKey: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(titleKey)
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(subtitleKey)
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
        .accessibilityLabel(Text(titleKey))
        .accessibilityValue(isOn ? Text("accessibility.value.on") : Text("accessibility.value.off"))
    }
}

#Preview {
    ToggleRow(titleKey: "togglerow.preview.title", subtitleKey: "togglerow.preview.subtitle", isOn: .constant(true))
        .padding()
}
