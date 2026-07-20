import Foundation

/// The single place that constructs a FilterPipeline with its real, concrete dependencies.
/// FilterPipeline itself never constructs its own dependencies — everything is injected —
/// so swapping PassthroughRuleCompiler for a SafariConverterLib-backed implementation (post
/// ADR-0001) only ever changes this file.
enum AppCompositionRoot {
    static let extensionIdentifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    static func makeFilterPipeline() -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            partitioner: GroupPartitioner(extensionIdentifiers: extensionIdentifiers),
            store: FilterStore(appGroupIdentifier: AppGroup.identifier),
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator()
        )
    }
}
