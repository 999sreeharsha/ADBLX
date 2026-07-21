// ADBLX/DesignSystem/Components/ComingSoonState.swift
import SwiftUI

/// Static placeholder for P1 screens with no backend yet (Sprint 4 spec §3/§9).
/// No ViewModel — there is nothing to load or mutate.
struct ComingSoonState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: DesignSpacing.stackGap) {
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(DesignColors.primary)
            Text(title)
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onBackground)
            Text(message)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Text("Coming Soon")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onPrimaryContainer)
                .padding(.horizontal, DesignSpacing.gutter)
                .padding(.vertical, DesignSpacing.base / 2)
                .background(DesignColors.primaryContainer)
                .clipShape(Capsule())
        }
        .padding(DesignSpacing.containerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ComingSoonState(
        title: "DNS Protection",
        message: "System-wide DNS filtering is coming in a future update. Available with Premium."
    )
}
