// ADBLX/Features/Premium/PremiumView.swift
import SwiftUI

struct PremiumView: View {
    @State var viewModel: PremiumViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                HStack {
                    Text("ADBLX Premium")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                    PremiumBadge()
                }

                Card {
                    featureRow("YouTube ad blocking in Safari")
                    Divider()
                    featureRow("System-wide DNS blocking")
                    Divider()
                    featureRow("Annoyance & regional filter lists")
                    Divider()
                    featureRow("iCloud sync across devices")
                }

                if let plans = viewModel.status?.plans {
                    VStack(spacing: DesignSpacing.stackGap) {
                        ForEach(plans) { plan in
                            planRow(plan)
                        }
                    }
                }

                if let error = viewModel.purchaseError {
                    Text(error.localizedDescription)
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.error)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
    }

    private func featureRow(_ title: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignColors.primary)
            Text(title)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
        }
    }

    private func planRow(_ plan: SubscriptionPlan) -> some View {
        Button {
            Task { await viewModel.purchase(planID: plan.id) }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(plan.name)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                    Text(plan.billingPeriodDescription)
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
                Spacer()
                Text(plan.priceDescription)
                    .font(DesignTypography.labelMono)
                    .foregroundStyle(DesignColors.onSurface)
            }
            .padding(DesignSpacing.containerPadding)
            .background(DesignColors.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.cardCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(plan.name), \(plan.priceDescription) \(plan.billingPeriodDescription)")
    }
}

#Preview {
    PremiumView(viewModel: PremiumViewModel(service: MockSubscriptionService()))
}
