// ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift
import SwiftUI

struct UpdateProgressSheet: View {
    @State var model: UpdateProgressModel
    let coordinator: UpdateCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: DesignSpacing.sectionGap) {
            if model.phase == .complete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(DesignColors.primary)
            } else if case .failed = model.phase {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(DesignColors.error)
            } else {
                ProgressView()
                    .tint(DesignColors.primary)
                    .scaleEffect(1.5)
            }

            Text(model.progressDescription)
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onBackground)
                .multilineTextAlignment(.center)

            if model.phase == .complete {
                PrimaryButton(titleKey: "updateprogress.button.done") { dismiss() }
            }
        }
        .padding(DesignSpacing.containerPadding)
        .task { await model.start(coordinator: coordinator) }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    UpdateProgressSheet(
        model: UpdateProgressModel(),
        coordinator: AppCompositionRoot.makeUpdateCoordinator(
            pipeline: AppCompositionRoot.makeFilterPipeline(store: AppCompositionRoot.makeFilterStore()),
            store: AppCompositionRoot.makeFilterStore()
        )
    )
}
