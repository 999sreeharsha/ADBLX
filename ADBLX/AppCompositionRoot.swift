import Foundation

/// The single place that constructs a FilterPipeline with its real, concrete dependencies.
/// FilterPipeline itself never constructs its own dependencies — everything is injected —
/// so swapping PassthroughRuleCompiler for a SafariConverterLib-backed implementation (post
/// ADR-0001) only ever changes this file.
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
