import Testing
import SwiftUI
import Foundation
@testable import ADBLX

/// Renders the plan card in each state to PNGs for review. Skipped unless
/// `TEST_RUNNER_PLAN_CARD_SNAPSHOT_DIR` names a directory, so it is not part of a normal run.
@Suite("Home plan card snapshots")
@MainActor
struct HomePlanCardSnapshots {
    private static let directory = ProcessInfo.processInfo.environment["PLAN_CARD_SNAPSHOT_DIR"]

    private let ids = GroupExtensionIdentifiers(ads: "ads", privacy: "privacy", annoyances: "annoyances", regional: "regional")
    private let endsAt = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Case {
        let name: String
        let plan: PlanState
        let resolved: Bool
        var enabled: Set<String> = ["ads", "privacy"]
    }

    @Test("renders every state", .enabled(if: directory != nil))
    func render() async throws {
        let directory = try #require(Self.directory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let cases = [
            Case(name: "unresolved", plan: .free, resolved: false),
            Case(name: "trial-chip-9", plan: .trial(daysRemaining: 9, endsAt: endsAt), resolved: true),
            Case(name: "trial-card-2", plan: .trial(daysRemaining: 2, endsAt: endsAt), resolved: true),
            Case(name: "protection", plan: .trialExpired(endedAt: endsAt), resolved: true),
            Case(name: "protection-safari-off", plan: .free, resolved: true, enabled: []),
            Case(name: "premium-hidden", plan: .premium(.lifetime), resolved: true)
        ]
        for item in cases {
            let model = HomePlanCardViewModel(
                dismissalStore: SnapshotStore(),
                stateProvider: SnapshotStateProvider(enabled: item.enabled),
                extensionIdentifiers: ids,
                subscriptionService: SnapshotSubscriptions(),
                dnsAvailable: false,
                now: { Date(timeIntervalSince1970: 1_790_000_000) }
            )
            await model.refresh(plan: item.plan, isResolved: item.resolved)
            for (variant, scheme, size) in [
                ("light", ColorScheme.light, DynamicTypeSize.large),
                ("dark", .dark, .large),
                ("dark-xxxl", .dark, .accessibility3)
            ] {
                let view = HomePlanCardView(
                    viewModel: model, subscriptionService: SnapshotSubscriptions(),
                    plan: item.plan, isResolved: item.resolved
                )
                .padding(DesignSpacing.containerPadding)
                .frame(width: 390, alignment: .topLeading)
                .background(DesignColors.background)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size)

                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let png = try #require(renderer.uiImage?.pngData(), "\(item.name) \(variant) did not render")
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(item.name)-\(variant).png"))
            }
        }
    }
}

private nonisolated final class SnapshotStore: PlanCardDismissalStoring, @unchecked Sendable {
    func load() -> HomePlanDismissals { HomePlanDismissals() }
    func save(_ dismissals: HomePlanDismissals) {}
}

private nonisolated struct SnapshotStateProvider: ContentBlockerStateProviding {
    let enabled: Set<String>
    func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState {
        enabled.contains(extensionIdentifier) ? .enabled : .disabled
    }
}

private struct SnapshotSubscriptions: SubscriptionService {
    func fetchStatus() async -> SubscriptionStatus {
        SubscriptionStatus(isPremium: false, plans: [
            SubscriptionPlan(id: "annual", name: "Annual", priceDescription: "$9.99", billingPeriodDescription: "", isCurrentPlan: false),
            SubscriptionPlan(id: "lifetime", name: "Lifetime", priceDescription: "$29.99", billingPeriodDescription: "", isCurrentPlan: false)
        ])
    }
    func purchase(_ planID: String) async throws -> Bool { false }
    func restorePurchases() async throws {}
}
