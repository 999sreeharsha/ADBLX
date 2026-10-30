import Foundation

/// Where UpdateCoordinator fetches manifest.json from. A separate abstraction from
/// UpdateCoordinator itself so the update-orchestration logic stays stable while the
/// manifest source (today: a placeholder; eventually: environment-specific CDN URLs
/// for debug/staging/release) can change without touching the coordinator.
protocol ManifestEndpointProvider: Sendable {
    var manifestURL: URL { get }
}

struct AppManifestEndpointProvider: ManifestEndpointProvider {
    let manifestURL = URL(string: "https://999sreeharsha.github.io/ADBLX/manifest.json")!
}

/// The single place that constructs a FilterPipeline with its real, concrete dependencies.
/// FilterPipeline itself never constructs its own dependencies — everything is injected —
/// so swapping PassthroughRuleCompiler for a SafariConverterLib-backed implementation (post
/// ADR-0001) only ever changes this file.
public enum AppCompositionRoot {
    static var extensionIdentifiers: GroupExtensionIdentifiers {
        let base = Bundle.main.bundleIdentifier ?? "com.ADBLX.ADBLX"
        return GroupExtensionIdentifiers(
            ads: "\(base).AdsBlocker",
            privacy: "\(base).PrivacyBlocker",
            annoyances: "\(base).AnnoyancesBlocker",
            regional: "\(base).RegionalBlocker"
        )
    }

    /// The single `FilterStore` instance shared by `FilterPipeline`, `UpdateCoordinator`,
    /// and every real UI service that reads App Group metadata. Callers must not construct
    /// their own `FilterStore` — always route through this factory so there is exactly one
    /// instance app-wide (Sprint 5A design doc).
    static func makeFilterStore() -> FilterStore {
        FilterStore(appGroupIdentifier: AppGroup.identifier)
    }

    static func makeFilterPipeline(store: FilterStore, allowlistStore: AllowlistStore? = nil) -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: NativeRuleCompilerAdapter(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: extensionIdentifiers),
            store: store,
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator(),
            allowlistStore: allowlistStore ?? makeAllowlistStore(store: store)
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

    private static let sharedTrialKeychainStore = TrialKeychainStore()
    private static let sharedTrialManager = TrialManager(store: sharedTrialKeychainStore)
    private static let sharedSubscriptionService = StoreKitSubscriptionService(trialManager: sharedTrialManager)

    /// The single `TrialManager` instance shared app-wide.
    public static func makeTrialManager() -> TrialManager {
        sharedTrialManager
    }

    /// The single `StoreKitSubscriptionService` instance shared app-wide.
    public static func makeSubscriptionService() -> StoreKitSubscriptionService {
        sharedSubscriptionService
    }

    private static let sharedWebExtensionEntitlementCoordinator: WebExtensionEntitlementCoordinator = {
        let coordinator = WebExtensionEntitlementCoordinator(entitlementService: sharedSubscriptionService)
        coordinator.startObserving()
        return coordinator
    }()

    /// The single `WebExtensionEntitlementCoordinator` instance shared app-wide.
    public static func makeWebExtensionEntitlementCoordinator() -> WebExtensionEntitlementCoordinator {
        sharedWebExtensionEntitlementCoordinator
    }

    private static let sharedTrialNotificationScheduler: TrialNotificationScheduler = {
        let scheduler = TrialNotificationScheduler(entitlementService: sharedSubscriptionService)
        Task {
            await scheduler.startObserving()
        }
        return scheduler
    }()

    /// The single `TrialNotificationScheduler` instance shared app-wide.
    public static func makeTrialNotificationScheduler() -> TrialNotificationScheduler {
        sharedTrialNotificationScheduler
    }

    private static let sharedTrialDecisionStore = TrialKeychainDecisionStore()

    /// The single `TrialDecisionStore` instance shared app-wide.
    public static func makeTrialDecisionStore() -> TrialDecisionStoreProtocol {
        sharedTrialDecisionStore
    }

    @MainActor
    private static let sharedTrialExpiryRouter = TrialExpiryRouter(
        entitlementService: sharedSubscriptionService,
        trialManager: sharedTrialManager,
        decisionStore: sharedTrialDecisionStore
    )

    /// The single `TrialExpiryRouter` instance shared app-wide.
    @MainActor
    public static func makeTrialExpiryRouter() -> TrialExpiryRouter {
        sharedTrialExpiryRouter
    }

    /// The single injectable throttle interval for launch-time update evaluation.
    /// PRD foreground throttle — kept as a static constant here (not user-configurable)
    /// so tests can construct their own UpdateThrottle with a different interval directly.
    static let updateThrottleInterval: TimeInterval = 6 * 60 * 60

    static func makeUpdateThrottle(store: FilterStore) -> UpdateThrottle {
        UpdateThrottle(store: store, interval: updateThrottleInterval)
    }

    /// The single `PlanStateModel` instance shared app-wide (owned here, injected into the
    /// view hierarchy by `ADBLXApp`; never accessed as a global by views).
    private static let sharedTrialSource = KeychainTrialSource(manager: sharedTrialManager, store: sharedTrialKeychainStore)

    static func makeTrialSource() -> TrialSource {
        sharedTrialSource
    }

    @MainActor
    private static let sharedPlanStateModel = PlanStateModel(
        provider: PlanStateProvider(
            trial: sharedTrialSource,
            paid: sharedSubscriptionService
        ),
        entitlementService: sharedSubscriptionService
    )

    @MainActor
    static func makePlanStateModel() -> PlanStateModel {
        sharedPlanStateModel
    }

    /// Level-triggered reconciler between installed premium filters and current entitlement.
    static func makePremiumEntitlementReconciler(
        pipeline: FilterPipeline,
        store: FilterStore
    ) -> PremiumEntitlementReconciler {
        PremiumEntitlementReconciler(
            store: store,
            pipeline: pipeline,
            manifestStore: ManifestStore(filterStore: store),
            reloader: ReloadCoordinator(),
            extensionIdentifiers: extensionIdentifiers,
            entitlementService: makeSubscriptionService()
        )
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
            extensionIdentifiers: extensionIdentifiers,
            entitlementService: makeSubscriptionService()
        )
    }

    static func makeBrokenSiteReporter(store: FilterStore) -> BrokenSiteReporting {
        let allowlistStore = makeAllowlistStore(store: store)
        let manifestStore = ManifestStore(filterStore: store)
        let dnsSettingsStore = DNSProtectionSettingsStore()
        return RealBrokenSiteReporter(
            allowlistStore: allowlistStore,
            manifestStore: manifestStore,
            dnsSettingsStore: dnsSettingsStore,
            session: makeHTTPSession()
        )
    }

    static func makeICloudSyncCoordinator(
        store: FilterStore,
        pipeline: FilterPipeline? = nil
    ) -> ICloudSyncCoordinator {
        let allowlistStore = makeAllowlistStore(store: store)
        return ICloudSyncCoordinator(
            allowlistStore: allowlistStore,
            pipeline: pipeline,
            entitlementService: makeSubscriptionService()
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
        let brokenSiteReporter: BrokenSiteReporting
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
        pipeline: FilterPipeline? = nil,
        updateCoordinator: UpdateCoordinator
    ) -> UIDependencies {
        switch configuration {
        case .mock:
            let preferencesStore = makeFilterPreferencesStore(store: store)
            let allowlistStore = makeAllowlistStore(store: store)
            let syncCoordinator = makeICloudSyncCoordinator(store: store, pipeline: pipeline)
            return UIDependencies(
                homeService: RealHomeService(store: store),
                protectionService: RealProtectionService(store: store, preferencesStore: preferencesStore),
                subscriptionService: makeSubscriptionService(),
                settingsService: RealSettingsService(
                    allowlistStore: allowlistStore,
                    pipeline: pipeline,
                    iCloudSyncCoordinator: syncCoordinator
                ),
                updateCoordinator: updateCoordinator,
                brokenSiteReporter: makeBrokenSiteReporter(store: store)
            )
        }
    }
}
