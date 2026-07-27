import Foundation

/// Where UpdateCoordinator fetches manifest.json from. A separate abstraction from
/// UpdateCoordinator itself so the update-orchestration logic stays stable while the
/// manifest source (today: a placeholder; eventually: environment-specific CDN URLs
/// for debug/staging/release) can change without touching the coordinator.
protocol ManifestEndpointProvider: Sendable {
    var manifestURL: URL { get }
}

struct AppManifestEndpointProvider: ManifestEndpointProvider {
    // TODO: replace with the real CDN manifest endpoint once available. Not a
    // Sprint 5 blocker — UpdateCoordinator.run() against this placeholder simply
    // fails, and the UI surfaces that as a real, honest error (Sprint 5B Commit 5).
    let manifestURL = URL(string: "https://example.invalid/manifest.json")!
}

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

    /// The one place an HTTPSession-conforming transport is constructed. ManifestClient
    /// and FilterDownloadClient both receive this same instance rather than each reaching
    /// for URLSession.shared independently.
    static func makeHTTPSession() -> HTTPSession {
        URLSession.shared
    }

    /// The single `FilterPreferencesStore` instance — same "one instance per backend
    /// type" principle as makeFilterStore(). No factory or service constructs its own.
    static func makeFilterPreferencesStore(store: FilterStore) -> FilterPreferencesStore {
        FilterPreferencesStore(store: store)
    }

    static func makeAllowlistStore(store: FilterStore) -> AllowlistStore {
        AllowlistStore(store: store)
    }

    /// The single injectable throttle interval for launch-time update evaluation.
    /// PRD foreground throttle — kept as a static constant here (not user-configurable)
    /// so tests can construct their own UpdateThrottle with a different interval directly.
    static let updateThrottleInterval: TimeInterval = 6 * 60 * 60

    static func makeUpdateThrottle(store: FilterStore) -> UpdateThrottle {
        UpdateThrottle(store: store, interval: updateThrottleInterval)
    }

    static func makeUpdateCoordinator(pipeline: FilterPipeline, store: FilterStore) -> UpdateCoordinator {
        let session = makeHTTPSession()
        let endpointProvider: ManifestEndpointProvider = AppManifestEndpointProvider()
        return UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: endpointProvider.manifestURL),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline,
            store: store,
            reloader: ReloadCoordinator(),
            extensionIdentifiers: extensionIdentifiers
        )
    }

    /// Holds every UI-facing service the app's screens depend on. Screens never
    /// construct services themselves — they receive them from here (or, in tests,
    /// construct their own mocks directly). Real implementations replace the
    /// mocks returned by makeUIDependencies(configuration:) in a later sprint; ViewModels
    /// and Views do not change when that happens (Sprint 4 spec §5).
    struct UIDependencies {
        let homeService: HomeService
        let protectionService: ProtectionService
        let subscriptionService: SubscriptionService
        let settingsService: SettingsService
        let updateCoordinator: UpdateCoordinator
    }

    /// Selects which set of backend implementations UIDependencies is built from.
    /// `.mock` still exists for SwiftUI previews and any future all-mock testing
    /// path; `homeService` itself is always RealHomeService now that it exists —
    /// Home has no reason to stay mockable once real (Sprint 5A design doc).
    enum UIDependenciesConfiguration {
        case mock
    }

    static func makeUIDependencies(
        configuration: UIDependenciesConfiguration,
        store: FilterStore,
        updateCoordinator: UpdateCoordinator
    ) -> UIDependencies {
        switch configuration {
        case .mock:
            let preferencesStore = makeFilterPreferencesStore(store: store)
            let allowlistStore = makeAllowlistStore(store: store)
            return UIDependencies(
                homeService: RealHomeService(store: store),
                protectionService: RealProtectionService(store: store, preferencesStore: preferencesStore),
                subscriptionService: MockSubscriptionService(),
                settingsService: RealSettingsService(allowlistStore: allowlistStore),
                updateCoordinator: updateCoordinator
            )
        }
    }
}
