// ADBLX/DesignSystem/Components/Card.swift
import SwiftUI

/// Borderless container relying on ambient shadow for definition (Stitch theme:
/// "Cards are the primary container... borderless, relying on the soft ambient
/// shadow for definition").
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.stackGap) {
            content()
        }
        .padding(DesignSpacing.containerPadding)
        .background(DesignColors.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.cardCornerRadius))
        .shadow(color: DesignColors.shadow, radius: 20, x: 0, y: 4)
    }
}

#Preview {
    Card {
        Text("card.preview.title")
        Text("card.preview.status")
    }
    .padding()
}
