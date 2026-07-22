// ADBLX/DesignSystem/Components/PrimaryButton.swift
import SwiftUI

/// The solid Privacy-Purple action button used throughout the app (Stitch
/// theme: "Primary buttons use a solid Privacy Purple fill with white text").
struct PrimaryButton: View {
    let titleKey: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(titleKey)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSpacing.base * 1.5)
        }
        .background(DesignColors.primary)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.buttonCornerRadius))
    }
}

#Preview {
    PrimaryButton(titleKey: "primarybutton.preview.title") {}
        .padding()
}
