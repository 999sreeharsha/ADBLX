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

    /// The single `FilterStore` instance shared by `FilterPipeline`, `UpdateCoordinator`,
    /// and every real UI service that reads App Group metadata. Callers must not construct
    /// their own `FilterStore` — always route through this factory so there is exactly one
    /// instance app-wide (Sprint 5A design doc).
    static func makeFilterStore() -> FilterStore {
        FilterStore(appGroupIdentifier: AppGroup.identifier)
    }

    static func makeFilterPipeline(store: FilterStore) -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: extensionIdentifiers),
            store: store,
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator()
        )
    }

    /// Holds every UI-facing service the app's screens depend on. Screens never
    /// construct services themselves — they receive them from here (or, in tests,
    /// construct their own mocks directly). Real implementations replace the
    /// mocks returned by makeMockUIDependencies() in a later sprint; ViewModels
    /// and Views do not change when that happens (Sprint 4 spec §5).
    struct UIDependencies {
        let homeService: HomeService
        let protectionService: ProtectionService
        let subscriptionService: SubscriptionService
        let settingsService: SettingsService
    }

    static func makeMockUIDependencies() -> UIDependencies {
        UIDependencies(
            homeService: MockHomeService(),
            protectionService: MockProtectionService(),
            subscriptionService: MockSubscriptionService(),
            settingsService: MockSettingsService()
        )
    }
}
