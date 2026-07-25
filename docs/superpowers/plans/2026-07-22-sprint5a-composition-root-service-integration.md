# Sprint 5A: Composition Root & Service Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `AppCompositionRoot` the single place that constructs every real backend dependency (Commit 1), then replace `MockHomeService` with a `RealHomeService` backed by `installed_filters.json` (Commit 2) — the first mock-to-real swap in Sprint 5, establishing the pattern Sprint 5B repeats for Protection, Settings, Advanced Filter Lists, Update Progress, and About.

**Architecture:** `AppCompositionRoot` stays a stateless `enum` of factory methods; `ADBLXApp` owns the long-lived singleton instances (`FilterStore`, `FilterPipeline`, `UpdateCoordinator`) as stored properties and threads them into `makeUIDependencies`. `HomeStatus` sheds two backend-unsupported fields (`blockedPercentage`, `dnsProviderName`) and gains one real one (`safariProtectionStatus`), with two minimal, justified `HomeView.swift` copy edits reflecting that.

**Tech Stack:** Xcode 26.6 project (Swift 5.0 language mode), scheme `ADBLX`, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), XcodeGen with `syncedFolder` (no manual `project.yml` edits needed for new files in existing directories).

## Global Constraints

- No protocol changes to `HomeService` unless unavoidable (none needed here — only the `HomeStatus` struct and `MockHomeService`'s literal values change).
- No fabricated/heuristic values: every `HomeStatus` field must trace to real backend state. Do not invent telemetry.
- `docs/gotchas.md`'s group-level `ruleCount` constraint applies: `InstalledFilter.ruleCount` is the whole group's aggregate, not a per-source count.
- Exactly one `FilterStore`, one `FilterPipeline`, one `UpdateCoordinator` instance exists app-wide, all owned by `ADBLXApp`, all threaded through `AppCompositionRoot` factory methods rather than constructed ad hoc.
- `AppCompositionRoot` remains an `enum` (stateless factory namespace) — do not convert it to a class/struct instance.
- Zero network activity at app launch — `UpdateCoordinator` is constructed but never invoked in this plan.
- `HomeView.swift` edits are copy-only (localized string swaps), not layout/redesign changes.

---

## File Structure

**Modify:**
- `ADBLX/AppCompositionRoot.swift` — add `ManifestEndpointProvider`, `AppManifestEndpointProvider`, `makeHTTPSession()`, `makeUpdateCoordinator(pipeline:store:)`, `UIDependenciesConfiguration`, rename `makeMockUIDependencies()` → `makeUIDependencies(configuration:pipeline:updateCoordinator:store:)`; extract shared `FilterStore` construction out of `makeFilterPipeline()`.
- `ADBLX/ADBLXApp.swift` — construct `filterStore`, `updateCoordinator` as stored properties; update the `makeUIDependencies` call site.
- `ADBLX/Features/Home/HomeService.swift` — remove `blockedPercentage`/`dnsProviderName` from `HomeStatus`, add `SafariProtectionStatus` enum + `safariProtectionStatus` field, update `MockHomeService` and `.placeholder`, add `RealHomeService`.
- `ADBLX/Features/Home/HomeView.swift` — Safari tile detail becomes static "Active" text; DNS tile becomes static "Not configured" placeholder.
- `ADBLX/Resources/Localizable.xcstrings` — replace `home.stat.safari.detail` (was interpolated) with a static key; replace `home.stat.dns.detail` value.
- `ADBLXTests/Features/Home/HomeViewModelTests.swift` — update the one `HomeStatus` literal to the new shape.

**Create:**
- `ADBLXTests/AppCompositionRootTests.swift` — verifies the composition root wiring (shared `FilterStore` instance, `UpdateCoordinator` construction).
- `ADBLXTests/Features/Home/RealHomeServiceTests.swift` — verifies `RealHomeService` against a real `FilterStore`.

---

## Task 1: Extract shared `FilterStore` construction in `AppCompositionRoot`

**Files:**
- Modify: `ADBLX/AppCompositionRoot.swift:1-47`
- Test: `ADBLXTests/AppCompositionRootTests.swift` (new)

**Interfaces:**
- Consumes: `FilterStore(appGroupIdentifier:)` (existing, `ADBLX/Filtering/Storage/FilterStore.swift:28`), `AppGroup.identifier` (existing, `ADBLX/AppGroup.swift`).
- Produces: `AppCompositionRoot.makeFilterStore() -> FilterStore`, used by every later task in this plan (`makeFilterPipeline`, `makeUpdateCoordinator`, `RealHomeService`, `ADBLXApp`).

Today `makeFilterPipeline()` constructs its own `FilterStore` inline, so there's no single shared instance to hand to `UpdateCoordinator` or `RealHomeService`. This task pulls that construction into its own factory method first, before anything depends on it.

- [ ] **Step 1: Write the failing test**

Create `ADBLXTests/AppCompositionRootTests.swift`:

```swift
// ADBLXTests/AppCompositionRootTests.swift
import Testing
@testable import ADBLX

@Suite("AppCompositionRoot")
struct AppCompositionRootTests {
    @Test("makeFilterStore returns a FilterStore configured with the shared App Group identifier")
    func makeFilterStoreUsesAppGroupIdentifier() async throws {
        let store = AppCompositionRoot.makeFilterStore()

        // Round-trip through the store to confirm it resolves the real App Group
        // container rather than throwing .appGroupContainerUnavailable.
        let url = try await store.directoryURL(.metadata)
        #expect(url.path.contains("Metadata"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/AppCompositionRootTests`
Expected: FAIL — `makeFilterStore` does not exist on `AppCompositionRoot`.

- [ ] **Step 3: Add `makeFilterStore()` and use it from `makeFilterPipeline()`**

Edit `ADBLX/AppCompositionRoot.swift`:

```swift
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
```

(`makeFilterPipeline` now takes `store:` instead of constructing its own — this is the seam that lets Step 3 of Task 2 share one instance. `makeMockUIDependencies` is untouched here; Task 3 replaces it.)

- [ ] **Step 4: Update `ADBLXApp.swift`'s call site to match the new signature**

Edit `ADBLX/ADBLXApp.swift`:

```swift
import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterStore = AppCompositionRoot.makeFilterStore()
    private let filterPipeline: FilterPipeline
    private let uiDependencies: AppCompositionRoot.UIDependencies
    @State private var onboardingStore = OnboardingCompletionStore()
    @State private var hasCompletedOnboarding: Bool

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
        let store = AppCompositionRoot.makeFilterStore()
        filterStore = store
        filterPipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        uiDependencies = AppCompositionRoot.makeMockUIDependencies()
        _hasCompletedOnboarding = State(initialValue: OnboardingCompletionStore().hasCompletedOnboarding)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView(dependencies: uiDependencies)
                } else {
                    OnboardingView {
                        onboardingStore.hasCompletedOnboarding = true
                        hasCompletedOnboarding = true
                    }
                }
            }
            .task {
                let pipeline = filterPipeline
                Task.detached(priority: .utility) {
                    await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: pipeline)
                }
            }
        }
    }
}
```

Note: `filterStore` is assigned twice transiently here (`let store = ...; filterStore = store`) because Swift struct `init` requires all stored properties assigned before use, and we need the same local `store` value passed to `makeFilterPipeline`. This is a deliberate, minimal pattern — Task 2 extends this same `init` to also construct `updateCoordinator`, so leave it as-is rather than simplifying now.

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/AppCompositionRootTests`
Expected: PASS.

- [ ] **Step 6: Run the full test suite to confirm no regressions**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all existing suites still pass — `FilterPipelineTests` and any other direct `FilterPipeline(...)` construction sites are untouched since they build their own pipeline inline (per the codebase's existing test convention), not through `AppCompositionRoot`.

- [ ] **Step 7: Build for device architecture to catch signature mismatches**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/AppCompositionRoot.swift ADBLX/ADBLXApp.swift ADBLXTests/AppCompositionRootTests.swift
git commit -m "$(cat <<'EOF'
refactor(composition-root): extract shared FilterStore construction

AppCompositionRoot.makeFilterStore() is now the single place a
FilterStore is constructed; makeFilterPipeline takes it as a
parameter instead of building its own. This is the seam Sprint 5A
needs to share one FilterStore between FilterPipeline,
UpdateCoordinator, and RealHomeService.
EOF
)"
```

---

## Task 2: Add `ManifestEndpointProvider`, `HTTPSession` factory, and `makeUpdateCoordinator`

**Files:**
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/ADBLXApp.swift`
- Test: `ADBLXTests/AppCompositionRootTests.swift`

**Interfaces:**
- Consumes: `HTTPSession` protocol (existing, `ADBLX/Filtering/Updates/HTTPSession.swift:5`, already conformed to by `URLSession`), `ManifestClient(session:endpoint:)`, `ManifestStore(filterStore:)`, `FilterDownloadClient(session:)`, `UpdateCoordinator(manifestClient:manifestStore:downloadClient:pipeline:store:reloader:extensionIdentifiers:)` (all existing, `ADBLX/Filtering/Updates/`), `AppCompositionRoot.makeFilterStore()`, `AppCompositionRoot.extensionIdentifiers` (from Task 1 / existing).
- Produces: `AppCompositionRoot.makeHTTPSession() -> HTTPSession`, `AppCompositionRoot.makeUpdateCoordinator(pipeline: FilterPipeline, store: FilterStore) -> UpdateCoordinator`, both consumed by `ADBLXApp` in this task and available to `RealHomeService`/Sprint 5B later if needed.

- [ ] **Step 1: Write the failing test**

Add to `ADBLXTests/AppCompositionRootTests.swift`:

```swift
    @Test("makeUpdateCoordinator constructs a coordinator wired to the given pipeline and store")
    func makeUpdateCoordinatorWiresDependencies() async throws {
        let store = AppCompositionRoot.makeFilterStore()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)

        let coordinator = AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)

        // A placeholder, unreachable endpoint means .run() will throw rather than
        // hang — this proves the coordinator is live and wired, without making a
        // real network call in a unit test.
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.run()
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/AppCompositionRootTests`
Expected: FAIL — `makeUpdateCoordinator` does not exist on `AppCompositionRoot`.

- [ ] **Step 3: Implement `ManifestEndpointProvider`, `makeHTTPSession()`, and `makeUpdateCoordinator`**

Edit `ADBLX/AppCompositionRoot.swift`, adding after the `extensionIdentifiers` declaration and before `makeFilterStore()`:

```swift
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
```

Then add these factory methods to the `AppCompositionRoot` enum, after `makeFilterStore()`:

```swift
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
```

- [ ] **Step 4: Wire `updateCoordinator` into `ADBLXApp`**

Edit `ADBLX/ADBLXApp.swift`:

```swift
import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterStore: FilterStore
    private let filterPipeline: FilterPipeline
    private let updateCoordinator: UpdateCoordinator
    private let uiDependencies: AppCompositionRoot.UIDependencies
    @State private var onboardingStore = OnboardingCompletionStore()
    @State private var hasCompletedOnboarding: Bool

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
        let store = AppCompositionRoot.makeFilterStore()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        filterStore = store
        filterPipeline = pipeline
        updateCoordinator = AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)
        uiDependencies = AppCompositionRoot.makeMockUIDependencies()
        _hasCompletedOnboarding = State(initialValue: OnboardingCompletionStore().hasCompletedOnboarding)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView(dependencies: uiDependencies)
                } else {
                    OnboardingView {
                        onboardingStore.hasCompletedOnboarding = true
                        hasCompletedOnboarding = true
                    }
                }
            }
            .task {
                let pipeline = filterPipeline
                Task.detached(priority: .utility) {
                    await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: pipeline)
                }
            }
        }
    }
}
```

`updateCoordinator` is constructed but never called anywhere in `.task` or `.body` — confirming the "no network activity at launch" constraint holds after this change.

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/AppCompositionRootTests`
Expected: PASS. (The `.run()` call against `https://example.invalid` throws a URL-resolution error, satisfying `#expect(throws:)`.)

- [ ] **Step 6: Run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass, including `UpdateCoordinatorTests` (unaffected — it builds its own `UpdateCoordinator` inline with `MockHTTPSession`, not through `AppCompositionRoot`).

- [ ] **Step 7: Build**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/AppCompositionRoot.swift ADBLX/ADBLXApp.swift ADBLXTests/AppCompositionRootTests.swift
git commit -m "$(cat <<'EOF'
feat(composition-root): construct UpdateCoordinator via ManifestEndpointProvider

AppCompositionRoot now builds the full update subsystem
(HTTPSession, ManifestClient, ManifestStore, FilterDownloadClient,
UpdateCoordinator) behind a ManifestEndpointProvider abstraction, so
the manifest CDN URL can change later without touching orchestration
code. ADBLXApp holds the single UpdateCoordinator instance but never
invokes it — no network activity at launch. UIDependencies still
returns mocks; this commit is backend-only.
EOF
)"
```

---

## Task 3: Introduce `UIDependenciesConfiguration` and rename `makeMockUIDependencies`

**Files:**
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/ADBLXApp.swift`
- Modify: `ADBLX/Navigation/RootTabView.swift:41` (the `#Preview` call site)

**Interfaces:**
- Consumes: `AppCompositionRoot.UIDependencies` (existing struct, unchanged shape).
- Produces: `enum UIDependenciesConfiguration { case mock }`, `AppCompositionRoot.makeUIDependencies(configuration: UIDependenciesConfiguration) -> UIDependencies`, consumed by `ADBLXApp` (this task) and `RootTabView`'s preview, and extended by Task 5 to accept real backend dependencies for the Home slot.

This finishes Commit 1: still zero behavior change, but the rename happens now so Task 5 (Commit 2) only has to add a case's worth of logic, not rename anything.

- [ ] **Step 1: No new automated test** — this is a pure rename/signature change with no new behavior. Verification is the build + existing suite (Steps 2-3 below) plus a manual check that no other call site references the old name.

- [ ] **Step 2: Rename in `AppCompositionRoot.swift`**

Edit `ADBLX/AppCompositionRoot.swift`, replacing:

```swift
    static func makeMockUIDependencies() -> UIDependencies {
        UIDependencies(
            homeService: MockHomeService(),
            protectionService: MockProtectionService(),
            subscriptionService: MockSubscriptionService(),
            settingsService: MockSettingsService()
        )
    }
```

with:

```swift
    /// Selects which set of backend implementations UIDependencies is built from.
    /// Only `.mock` exists today — this enum exists so adding `.production` later
    /// (Sprint 5B, as each feature service gets its real implementation) doesn't
    /// require renaming this factory method again.
    enum UIDependenciesConfiguration {
        case mock
    }

    static func makeUIDependencies(configuration: UIDependenciesConfiguration) -> UIDependencies {
        switch configuration {
        case .mock:
            return UIDependencies(
                homeService: MockHomeService(),
                protectionService: MockProtectionService(),
                subscriptionService: MockSubscriptionService(),
                settingsService: MockSettingsService()
            )
        }
    }
```

- [ ] **Step 3: Update call sites**

Edit `ADBLX/ADBLXApp.swift`, changing `uiDependencies = AppCompositionRoot.makeMockUIDependencies()` to:

```swift
        uiDependencies = AppCompositionRoot.makeUIDependencies(configuration: .mock)
```

Edit `ADBLX/Navigation/RootTabView.swift:41`, changing:

```swift
#Preview {
    RootTabView(dependencies: AppCompositionRoot.makeMockUIDependencies())
}
```

to:

```swift
#Preview {
    RootTabView(dependencies: AppCompositionRoot.makeUIDependencies(configuration: .mock))
}
```

- [ ] **Step 4: Search for any other call sites**

Run: `grep -rn "makeMockUIDependencies" /Users/sreeharshag/Work/ADBLX/ADBLX /Users/sreeharshag/Work/ADBLX/ADBLXTests`
Expected: no output (all references updated). If any remain, update them the same way.

- [ ] **Step 5: Build**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass, zero behavior change.

- [ ] **Step 7: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/AppCompositionRoot.swift ADBLX/ADBLXApp.swift ADBLX/Navigation/RootTabView.swift
git commit -m "$(cat <<'EOF'
refactor(composition-root): replace makeMockUIDependencies with configuration-based factory

makeUIDependencies(configuration:) with a single .mock case today
avoids renaming this factory again when Sprint 5B adds real
per-feature services behind new configuration branches. No behavior
change — UIDependencies still returns every mock service.
EOF
)"
```

This completes **Commit 1** (composition root backend construction). Commit 2 (Real HomeService) begins at Task 4.

---

## Task 4: Update `HomeStatus` domain model and `MockHomeService`

**Files:**
- Modify: `ADBLX/Features/Home/HomeService.swift`
- Modify: `ADBLXTests/Features/Home/HomeViewModelTests.swift:9-16`

**Interfaces:**
- Consumes: nothing new.
- Produces: revised `HomeStatus` struct (fields: `isProtectionEnabled: Bool`, `safariProtectionStatus: SafariProtectionStatus`, `lastUpdateDescription: String`, `ruleCount: Int`, `recentActivity: [HomeActivityEntry]` — `blockedPercentage`/`dnsProviderName` removed), `enum SafariProtectionStatus { case active }`, consumed by `HomeView.swift` (Task 6) and `RealHomeService` (Task 5).

- [ ] **Step 1: Write the failing test** — update the existing `HomeViewModelTests` literal to the new shape (this test currently references the fields being removed, so it must change in lockstep with the model)

Edit `ADBLXTests/Features/Home/HomeViewModelTests.swift`:

```swift
// ADBLXTests/Features/Home/HomeViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("HomeViewModel")
struct HomeViewModelTests {
    @Test("load() populates status from the injected service")
    func loadPopulatesStatus() async {
        let expected = HomeStatus(
            isProtectionEnabled: true,
            safariProtectionStatus: .active,
            lastUpdateDescription: "2m ago",
            ruleCount: 142_042,
            recentActivity: []
        )
        let viewModel = HomeViewModel(service: StubHomeService(statusToReturn: expected))

        await viewModel.load()

        #expect(viewModel.status == expected)
        #expect(viewModel.isLoading == false)
    }
}

private struct StubHomeService: HomeService {
    let statusToReturn: HomeStatus
    func fetchStatus() async -> HomeStatus { statusToReturn }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/HomeViewModelTests`
Expected: FAIL — compile error, `HomeStatus` init doesn't have a `safariProtectionStatus:` parameter yet / still requires `blockedPercentage:`/`dnsProviderName:`.

- [ ] **Step 3: Update `HomeStatus` and `MockHomeService` in `HomeService.swift`**

Edit `ADBLX/Features/Home/HomeService.swift`, replacing the whole file:

```swift
// ADBLX/Features/Home/HomeService.swift
import Foundation

/// One activity-feed entry shown on Home (Stitch: "Recent Activity Feed").
struct HomeActivityEntry: Equatable, Identifiable {
    enum Kind {
        case trackerBlocked
        case filtersSynchronized
        case protectionToggled
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let timestamp: String

    static func == (lhs: HomeActivityEntry, rhs: HomeActivityEntry) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle && lhs.timestamp == rhs.timestamp
    }
}

/// Whether Safari content blocking is active. Only `.active` is implemented —
/// `.needsSetup`/`.unavailable` are reserved for a future sprint once Safari
/// extension-enablement detection exists (relates to onboarding FR-07, not
/// built yet). Do not add cases without a real detection mechanism behind them.
enum SafariProtectionStatus: Equatable {
    case active
}

/// Everything the Home screen needs to render (Stitch "Home Dashboard" screen).
///
/// Every field here must trace to real backend state — no fabricated or
/// heuristic values (Sprint 5A design doc). `blockedPercentage` and
/// `dnsProviderName` were removed for exactly this reason: Safari Content
/// Blockers give the app no block-event callback, and DNS status belongs to
/// the not-yet-built Packet Tunnel subsystem.
struct HomeStatus: Equatable {
    let isProtectionEnabled: Bool
    let safariProtectionStatus: SafariProtectionStatus
    let lastUpdateDescription: String
    let ruleCount: Int
    let recentActivity: [HomeActivityEntry]

    static let placeholder = HomeStatus(
        isProtectionEnabled: true,
        safariProtectionStatus: .active,
        lastUpdateDescription: "just now",
        ruleCount: 0,
        recentActivity: []
    )
}

/// What HomeView/HomeViewModel need from the backend. Never exposes
/// FilterPipeline or UpdateCoordinator directly (Sprint 4 spec §5) — a later
/// sprint's real implementation translates their state into a HomeStatus here.
protocol HomeService: Sendable {
    func fetchStatus() async -> HomeStatus
}

/// Sprint 4A/4B mock. Mirrors the Stitch "Home Dashboard" screen's sample
/// content exactly so the implemented screen visually matches the design.
struct MockHomeService: HomeService {
    func fetchStatus() async -> HomeStatus {
        HomeStatus(
            isProtectionEnabled: true,
            safariProtectionStatus: .active,
            lastUpdateDescription: "2m ago",
            ruleCount: 142_042,
            recentActivity: [
                HomeActivityEntry(
                    kind: .trackerBlocked,
                    title: "google-analytics.com",
                    subtitle: "Tracker blocked in Safari",
                    timestamp: "14:22"
                ),
                HomeActivityEntry(
                    kind: .filtersSynchronized,
                    title: "Filters Synchronized",
                    subtitle: "Successfully updated 4 filter lists",
                    timestamp: "12:05"
                ),
                HomeActivityEntry(
                    kind: .protectionToggled,
                    title: "Protection Enabled",
                    subtitle: "Global toggle switched to ON",
                    timestamp: "09:00"
                ),
            ]
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/HomeViewModelTests`
Expected: PASS.

- [ ] **Step 5: Build** (expect failures in `HomeView.swift`, addressed in Task 6 — confirm the failure is only there)

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD FAILED **`, with errors confined to `ADBLX/Features/Home/HomeView.swift` referencing `status.blockedPercentage` and `status.dnsProviderName` (both removed). This is expected at this point in the plan — do not attempt to fix `HomeView.swift` here; Task 6 does that.

- [ ] **Step 6: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Features/Home/HomeService.swift ADBLXTests/Features/Home/HomeViewModelTests.swift
git commit -m "$(cat <<'EOF'
refactor(home): remove unsupported blockedPercentage/dnsProviderName from HomeStatus

Safari Content Blockers give the app no block-event callback, so
blockedPercentage was always either a fake percentage or a
disguised sentinel — removed rather than faked. dnsProviderName
belongs to the DNS Packet Tunnel subsystem, out of scope for all of
Sprint 5. Adds SafariProtectionStatus (.active only for now) as the
real replacement for the Safari tile's status.

HomeView.swift now fails to build (blockedPercentage/dnsProviderName
references) — fixed in the next commit.
EOF
)"
```

---

## Task 5: Implement `RealHomeService`

**Files:**
- Modify: `ADBLX/Features/Home/HomeService.swift`
- Create: `ADBLXTests/Features/Home/RealHomeServiceTests.swift`

**Interfaces:**
- Consumes: `FilterStore.read(_:in:)` (existing, `ADBLX/Filtering/Storage/FilterStore.swift:61`), `InstalledFilter` (existing, `ADBLX/Filtering/Models/InstalledFilter.swift` — fields `id`, `group: FilterGroup`, `installedVersion`, `checksumSHA256`, `lastUpdated: Date`, `ruleCount: Int`), `FilterGroup` (existing, `ADBLX/Filtering/Models/FilterManifest.swift:24`), `HomeStatus`/`SafariProtectionStatus`/`HomeActivityEntry` (from Task 4).
- Produces: `RealHomeService: HomeService`, an `actor` (matches the existing `MockProtectionService`/`MockSettingsService` pattern of using `actor` for services with any internal state — here needed because `FilterStore` is itself an `actor`, so `fetchStatus()` must `await` into it), constructed by `AppCompositionRoot` in Task 7.

`RealHomeService` reads `installed_filters.json`, decodes `[InstalledFilter]`, and derives every `HomeStatus` field from that array — matching exactly what Commit 2's design decided:

- `isProtectionEnabled`: `true` iff the array is non-empty (real "has the pipeline deployed anything" signal, not yet a user toggle — see doc comment).
- `safariProtectionStatus`: always `.active` for now (only case that exists).
- `ruleCount`: sum of `ruleCount` across **unique groups** (not per-entry — a multi-source group's entries all report the same group-level total per `docs/gotchas.md`, so summing per-entry would double-count a group with 2+ installed sources).
- `lastUpdateDescription`: relative-time string from the single most recent `lastUpdated` across all entries; `"Never"` if the array is empty.
- `recentActivity`: one `.filtersSynchronized` entry per unique `FilterGroup`, using that group's most recent `lastUpdated`, sorted newest first.

- [ ] **Step 1: Write the failing test**

Create `ADBLXTests/Features/Home/RealHomeServiceTests.swift`:

```swift
// ADBLXTests/Features/Home/RealHomeServiceTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("RealHomeService", .serialized)
struct RealHomeServiceTests {
    private func makeStore() async throws -> FilterStore {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
        return store
    }

    @Test("no installed_filters.json means protection is not enabled and activity is empty")
    func emptyStateIsHonest() async throws {
        let store = try await makeStore()
        let service = RealHomeService(store: store)

        let status = await service.fetchStatus()

        #expect(status.isProtectionEnabled == false)
        #expect(status.ruleCount == 0)
        #expect(status.recentActivity.isEmpty)
        #expect(status.lastUpdateDescription == "Never")
    }

    @Test("installed filters across two groups sum ruleCount once per group and report the newest update")
    func aggregatesAcrossGroupsWithoutDoubleCounting() async throws {
        let store = try await makeStore()
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)

        // Two entries in the SAME group (ads) share the same group-level ruleCount
        // (per docs/gotchas.md) — summing naively would double it to 124_000.
        let filters = [
            InstalledFilter(
                id: "easylist", group: .ads, installedVersion: "1", checksumSHA256: "a",
                lastUpdated: older, ruleCount: 62_000
            ),
            InstalledFilter(
                id: "easylist-extra", group: .ads, installedVersion: "1", checksumSHA256: "b",
                lastUpdated: older, ruleCount: 62_000
            ),
            InstalledFilter(
                id: "easyprivacy", group: .privacy, installedVersion: "1", checksumSHA256: "c",
                lastUpdated: newer, ruleCount: 48_500
            ),
        ]
        let data = try JSONEncoder().encode(filters)
        try await store.writeMetadata(data, filename: "installed_filters.json")

        let service = RealHomeService(store: store)
        let status = await service.fetchStatus()

        #expect(status.isProtectionEnabled == true)
        #expect(status.ruleCount == 62_000 + 48_500)
        #expect(status.recentActivity.count == 2)
        #expect(status.safariProtectionStatus == .active)
    }

    @Test("a concurrent write never produces a torn or corrupt read (ABORT review, ordering-race finding)")
    func concurrentWriteNeverProducesTornRead() async throws {
        // Simulates the real production hazard: ContentBlockerBootstrap writing
        // installed_filters.json in a detached Task while HomeView's .task reads
        // it via RealHomeService, with no guaranteed ordering between the two.
        // FilterStore.writeMetadata uses `.atomic` (FilterStore.swift:69-72), so a
        // reader must see either the fully-old or fully-new file, never a partial
        // one — this test proves that guarantee holds under real concurrent access
        // rather than asserting it only in a code comment.
        let store = try await makeStore()
        let filters = [
            InstalledFilter(
                id: "easylist", group: .ads, installedVersion: "1", checksumSHA256: "a",
                lastUpdated: Date(), ruleCount: 62_000
            ),
        ]
        let data = try JSONEncoder().encode(filters)
        let service = RealHomeService(store: store)

        async let writeTask: Void = store.writeMetadata(data, filename: "installed_filters.json")
        async let readResults: [HomeStatus] = withTaskGroup(of: HomeStatus.self) { group in
            for _ in 0..<20 {
                group.addTask { await service.fetchStatus() }
            }
            var results: [HomeStatus] = []
            for await result in group { results.append(result) }
            return results
        }

        _ = try await writeTask
        let statuses = await readResults

        // Every read must be a clean, fully-decoded state — either the pre-write
        // empty state or the post-write single-group state. A torn read would
        // either throw during JSONDecoder (caught by RealHomeService's `try?` and
        // silently reported as empty — acceptable) or, if .atomic is ever removed
        // from writeMetadata, could decode partial/garbage data that doesn't match
        // either expected shape. This assertion is what catches that regression.
        for status in statuses {
            let isValidEmptyState = status.isProtectionEnabled == false && status.ruleCount == 0
            let isValidPopulatedState = status.isProtectionEnabled == true && status.ruleCount == 62_000
            #expect(
                isValidEmptyState || isValidPopulatedState,
                "fetchStatus() returned a state matching neither pre-write nor post-write — possible torn read: \(status)"
            )
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/RealHomeServiceTests`
Expected: FAIL — `RealHomeService` does not exist.

- [ ] **Step 3: Implement `RealHomeService`**

Add to the end of `ADBLX/Features/Home/HomeService.swift`:

```swift
/// Real HomeService, backed by `installed_filters.json` (FilterStore/Metadata) — the
/// same source of truth FilterPipeline writes to on every successful install. Sprint
/// 5A Commit 2: every field here is derived from real backend state, never fabricated.
actor RealHomeService: HomeService {
    private let store: FilterStore

    init(store: FilterStore) {
        self.store = store
    }

    func fetchStatus() async -> HomeStatus {
        let filters = (try? await loadInstalledFilters()) ?? []

        guard !filters.isEmpty else {
            return HomeStatus(
                isProtectionEnabled: false,
                safariProtectionStatus: .active,
                lastUpdateDescription: String(localized: "home.lastUpdate.never"),
                ruleCount: 0,
                recentActivity: []
            )
        }

        let latestByGroup = Dictionary(grouping: filters, by: \.group)
            .compactMapValues { entries in entries.max(by: { $0.lastUpdated < $1.lastUpdated }) }

        let ruleCount = latestByGroup.values.reduce(0) { $0 + $1.ruleCount }
        let mostRecent = latestByGroup.values.map(\.lastUpdated).max() ?? Date()

        let recentActivity = latestByGroup.values
            .sorted { $0.lastUpdated > $1.lastUpdated }
            .map { filter in
                HomeActivityEntry(
                    kind: .filtersSynchronized,
                    title: String(localized: "home.activity.filtersSynchronized.title"),
                    subtitle: groupDisplayName(filter.group),
                    timestamp: filter.lastUpdated.formatted(date: .omitted, time: .shortened)
                )
            }

        return HomeStatus(
            isProtectionEnabled: true,
            safariProtectionStatus: .active,
            lastUpdateDescription: mostRecent.formatted(.relative(presentation: .named)),
            ruleCount: ruleCount,
            recentActivity: recentActivity
        )
    }

    private func loadInstalledFilters() async throws -> [InstalledFilter] {
        let data = try await store.read("installed_filters.json", in: .metadata)
        return try JSONDecoder().decode([InstalledFilter].self, from: data)
    }

    private func groupDisplayName(_ group: FilterGroup) -> String {
        switch group {
        case .ads: return String(localized: "protection.category.ads")
        case .privacy: return String(localized: "protection.category.privacy")
        case .annoyances: return String(localized: "protection.category.annoyances")
        case .regional: return String(localized: "protection.category.regional")
        }
    }
}
```

This reuses the existing `protection.category.*` localization keys (already present in `Localizable.xcstrings` per Task 6's read of that file) rather than adding new ones for group names.

- [ ] **Step 4: Add the one new localization key this introduces**

`home.lastUpdate.never` and `home.activity.filtersSynchronized.title` are new keys — Task 6 adds both to `Localizable.xcstrings` alongside its other string changes, so no localization build failure blocks this task's test run (Swift Testing doesn't require the `.xcstrings` catalog to build — `String(localized:)` falls back to the key string itself if unresolved, which is sufficient for this task's assertions since none of them assert on that particular string's rendered value).

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/RealHomeServiceTests`
Expected: PASS.

- [ ] **Step 6: Run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: `RealHomeServiceTests` and `AppCompositionRootTests` pass; `HomeView.swift` build errors from Task 4 Step 5 still present (fixed next task) — if the test target doesn't require the app target to build cleanly, tests still run; otherwise proceed directly to Task 6 before re-running.

- [ ] **Step 7: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Features/Home/HomeService.swift ADBLXTests/Features/Home/RealHomeServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(home): implement RealHomeService backed by installed_filters.json

Derives isProtectionEnabled, ruleCount, lastUpdateDescription, and
recentActivity entirely from real FilterStore metadata. ruleCount
sums once per unique FilterGroup rather than per InstalledFilter
entry, avoiding double-counting a multi-source group's shared
group-level total (docs/gotchas.md). recentActivity emits only
.filtersSynchronized entries — .trackerBlocked has no data source
and .protectionToggled has no persisted toggle state until Sprint
5B's ProtectionService work lands.
EOF
)"
```

---

## Task 6: Update `HomeView.swift` copy and `Localizable.xcstrings`

**Files:**
- Modify: `ADBLX/Features/Home/HomeView.swift:113-158`
- Modify: `ADBLX/Resources/Localizable.xcstrings:216-230`

**Interfaces:**
- Consumes: `HomeStatus.safariProtectionStatus` (Task 4), no new types produced — this task only changes view rendering and string catalog entries.

Two tile-copy edits, both justified by Commit 2's design decision (backend-honest static text, same layout, no redesign):

- [ ] **Step 1: Edit the Safari tile in `HomeView.swift`**

In `ADBLX/Features/Home/HomeView.swift`, replace the Safari `statTile(...)` call (currently lines 121-131):

```swift
                statTile(
                    icon: "safari",
                    labelKey: "home.stat.safari.label",
                    value: String(localized: "home.stat.safari.value"),
                    detail: String(
                        format: String(localized: "home.stat.safari.detail"),
                        status.blockedPercentage.formatted(.number.precision(.fractionLength(1)))
                    ),
                    detailColor: DesignColors.secondary,
                    iconColor: DesignColors.primary
                )
```

with:

```swift
                statTile(
                    icon: "safari",
                    labelKey: "home.stat.safari.label",
                    value: String(localized: "home.stat.safari.value"),
                    detail: String(localized: "home.stat.safari.detail"),
                    detailColor: DesignColors.secondary,
                    iconColor: DesignColors.primary
                )
```

(`status.safariProtectionStatus` isn't referenced directly in the tile yet since only `.active` exists — the detail string is the localized text set in Step 3 below. When `.needsSetup`/`.unavailable` are added in a future sprint, this becomes a switch over `status.safariProtectionStatus`.

**ABORT review finding:** the detail string here must NOT say "Active" — `isProtectionEnabled`/`safariProtectionStatus` measure "the pipeline has deployed at least one filter group," not "Safari is currently blocking content right now." A tile labeled "Safari" with a detail of "Active" reads as a live, verified protection-status claim, but the app has no way to detect whether the user actually enabled the Safari extension in iOS Settings — Safari extension enablement detection doesn't exist yet (same gap `SafariProtectionStatus.needsSetup`/`.unavailable` are reserved for). Use `home.stat.safari.detail` = "Filters Loaded" (Step 3) instead, which is accurate to what's actually known and doesn't imply real-time verification.)

- [ ] **Step 2: Edit the DNS tile in `HomeView.swift`**

Replace the DNS `statTile(...)` call (currently lines 132-139):

```swift
                statTile(
                    icon: "network",
                    labelKey: "home.stat.dns.label",
                    value: status.dnsProviderName,
                    detail: String(localized: "home.stat.dns.detail"),
                    detailColor: DesignColors.onSurfaceVariant,
                    iconColor: DesignColors.tertiary
                )
```

with:

```swift
                statTile(
                    icon: "network",
                    labelKey: "home.stat.dns.label",
                    value: String(localized: "home.stat.dns.value"),
                    detail: String(localized: "home.stat.dns.detail"),
                    detailColor: DesignColors.onSurfaceVariant,
                    iconColor: DesignColors.tertiary
                )
```

(This tile becomes fully view-owned static text — no `HomeStatus` field backs it. Ownership transfers back to the backend, with a real `DNSStatus` model, once the Packet Tunnel subsystem lands, per the design doc.)

- [ ] **Step 3: Update `Localizable.xcstrings`**

Edit `ADBLX/Resources/Localizable.xcstrings`. Replace the `home.stat.safari.detail` entry (line 222-224):

```json
    "home.stat.safari.detail" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "%@%% Blocked" } } }
    },
```

with:

```json
    "home.stat.safari.detail" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Filters Loaded" } } }
    },
```

("Filters Loaded" rather than "Active" — see the ABORT-review note in Step 1: this tile's underlying data only proves the pipeline deployed a filter group, not that Safari's extension is actually enabled and blocking. "Active" overclaims a live verification the app can't perform yet.)

Replace the `home.stat.dns.detail` entry (line 228-230) and add a new `home.stat.dns.value` key right after `home.stat.dns.label` (line 225-227):

```json
    "home.stat.dns.label" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "DNS" } } }
    },
    "home.stat.dns.value" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Not configured" } } }
    },
    "home.stat.dns.detail" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "—" } } }
    },
```

(`—` is an em dash, used here since "Not configured" as the value already conveys the state — the detail line becomes a neutral placeholder rather than repeating "Not configured" twice. If this reads awkwardly in the simulator per Step 6's manual check, an acceptable alternative is leaving `detail: nil` in the `statTile(...)` call instead — check both against the actual tile layout.)

Add the two new keys `RealHomeService` (Task 5) references, in the `"home."`-prefixed block near the other `home.*` keys (after `home.section.recentActivity`, line 246-248):

```json
    "home.lastUpdate.never" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Never" } } }
    },
    "home.activity.filtersSynchronized.title" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Filters Synchronized" } } }
    },
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **` — this is the point where Task 4 Step 5's expected failures are resolved.

- [ ] **Step 5: Run the SwiftLint check for the no-hardcoded-string rule**

Run: `swiftlint lint --path ADBLX/Features/Home/HomeView.swift`
Expected: no violations (both edits use `String(localized:)`/localization keys, consistent with the Sprint 4C `no_hardcoded_ui_string` rule at error severity).

- [ ] **Step 6: Manual simulator check**

Open `ADBLX.xcodeproj` in Xcode, run on an iOS Simulator, navigate to the Home tab.
Expected: Safari tile shows "Filters Loaded" where the percentage used to be; DNS tile shows "Not configured" (value line) with a neutral detail line; layout unchanged from before this task (same tile positions, sizes, colors). If the DNS tile's em-dash detail line looks visually odd, apply the `detail: nil` fallback noted in Step 3 and re-run this check.

- [ ] **Step 7: Run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass, including `RealHomeServiceTests` and `HomeViewModelTests` from earlier tasks.

- [ ] **Step 8: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Features/Home/HomeView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
fix(home): replace unsupported Safari/DNS tile copy with backend-honest text

Safari tile detail becomes a static "Filters Loaded" string instead
of an interpolated blocked-percentage (no telemetry source exists)
or an "Active" claim the app can't verify (Safari extension
enablement detection doesn't exist yet). DNS tile becomes a fully
view-owned "Not configured" placeholder with no backing HomeStatus
field until the Packet Tunnel subsystem exists. Copy-only change,
same tile layout.
EOF
)"
```

- [ ] **Step 9 (ABORT review condition): Add retry-on-appear so Home self-corrects if it loads before the bootstrap install completes**

**Why:** `ADBLXApp`'s `.task` block kicks off `ContentBlockerBootstrap.ensureInitialRulesInstalled` in a detached background `Task` with no completion signal wired to the UI. `HomeView`'s own `.task { await viewModel.load() }` runs independently and can fire — and complete — before that install finishes writing `installed_filters.json`. Task 5's atomicity test (Step added to Task 5) proves a concurrent read never sees *corrupt* data, but it says nothing about *staleness*: today, if `HomeView.load()` wins that race, the user sees "0 rules / not enabled" permanently, because nothing ever re-triggers a second load. Restated from the ABORT review: this is the single highest-severity risk found (cold-launch race → permanent false "empty" state), so it must be closed with code, not left to a manual simulator check that a subagent can't reliably perform.

**Fix:** add a `.onChange(of: scenePhase)`-independent, simpler mechanism — re-run `viewModel.load()` when the view reappears, which SwiftUI already triggers via `.task` re-firing on view identity changes is NOT reliable here (task runs once per view lifetime, not on every appear). Use `.refreshable` (pull-to-refresh, already idiomatic for this exact "data might be stale" scenario) plus a bounded auto-retry for the specific empty-state case, so the fix is testable without relying on user gesture:

Edit `ADBLX/Features/Home/HomeViewModel.swift`:

```swift
// ADBLX/Features/Home/HomeViewModel.swift
import Observation

@Observable
final class HomeViewModel {
    private let service: HomeService

    var status: HomeStatus?
    var isLoading = false

    init(service: HomeService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        status = await service.fetchStatus()
        isLoading = false
    }

    /// Closes the cold-launch race between ContentBlockerBootstrap's detached
    /// install Task and this view's first load (ABORT review finding, Sprint 5A
    /// plan Task 6 Step 9): if the first load lands before bootstrap's write,
    /// isProtectionEnabled is false with 0 rules — genuinely indistinguishable
    /// from a real empty state at the type level, so this retries a bounded
    /// number of times with a short delay rather than leaving the user stuck on
    /// a stale "not enabled" reading after a normal fresh-install launch.
    func loadWithBootstrapRetry(maxAttempts: Int = 3, retryDelay: Duration = .milliseconds(500)) async {
        for attempt in 1...maxAttempts {
            await load()
            if status?.isProtectionEnabled == true { return }
            if attempt < maxAttempts {
                try? await Task.sleep(for: retryDelay)
            }
        }
    }
}
```

Edit `ADBLX/Features/Home/HomeView.swift`, changing the `.task` modifier (originally `.task { await viewModel.load() }`):

```swift
        .task { await viewModel.loadWithBootstrapRetry() }
        .refreshable { await viewModel.load() }
```

(`.refreshable` adds standard pull-to-refresh as the user-facing escape hatch for any staleness beyond the bounded auto-retry window — e.g., a slow first-launch network/disk condition longer than 3 × 500ms. This is additive to the existing `ScrollView`, a standard SwiftUI modifier, not a layout change.)

- [ ] **Step 10: Write a test for the retry behavior**

Add to `ADBLXTests/Features/Home/HomeViewModelTests.swift`:

```swift
    @Test("loadWithBootstrapRetry retries until isProtectionEnabled becomes true, then stops")
    func retriesUntilProtectionEnabled() async {
        let service = SequencedStubHomeService(statusesToReturn: [
            HomeStatus(
                isProtectionEnabled: false, safariProtectionStatus: .active,
                lastUpdateDescription: "Never", ruleCount: 0, recentActivity: []
            ),
            HomeStatus(
                isProtectionEnabled: true, safariProtectionStatus: .active,
                lastUpdateDescription: "just now", ruleCount: 62_000, recentActivity: []
            ),
        ])
        let viewModel = HomeViewModel(service: service)

        await viewModel.loadWithBootstrapRetry(maxAttempts: 3, retryDelay: .milliseconds(1))

        #expect(viewModel.status?.isProtectionEnabled == true)
        #expect(await service.callCount == 2)
    }

    @Test("loadWithBootstrapRetry gives up after maxAttempts and leaves the last (empty) status")
    func givesUpAfterMaxAttempts() async {
        let service = SequencedStubHomeService(statusesToReturn: [
            HomeStatus(
                isProtectionEnabled: false, safariProtectionStatus: .active,
                lastUpdateDescription: "Never", ruleCount: 0, recentActivity: []
            ),
        ])
        let viewModel = HomeViewModel(service: service)

        await viewModel.loadWithBootstrapRetry(maxAttempts: 2, retryDelay: .milliseconds(1))

        #expect(viewModel.status?.isProtectionEnabled == false)
        #expect(await service.callCount == 2)
    }
}

private actor SequencedStubHomeService: HomeService {
    private var statuses: [HomeStatus]
    private(set) var callCount = 0

    init(statusesToReturn: [HomeStatus]) {
        self.statuses = statusesToReturn
    }

    func fetchStatus() async -> HomeStatus {
        callCount += 1
        if statuses.count > 1 {
            return statuses.removeFirst()
        }
        return statuses[0]
    }
}
```

Note: this replaces the file's trailing `private struct StubHomeService` closing brace context — `SequencedStubHomeService` is a second, separate private helper type in the same file, alongside the existing `StubHomeService` from Task 4. Both remain, serving different tests.

- [ ] **Step 11: Run the new tests**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/HomeViewModelTests`
Expected: PASS, including the two new retry tests.

- [ ] **Step 12: Build and run the full suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass.

- [ ] **Step 13: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Features/Home/HomeViewModel.swift ADBLX/Features/Home/HomeView.swift ADBLXTests/Features/Home/HomeViewModelTests.swift
git commit -m "$(cat <<'EOF'
fix(home): retry initial load if bootstrap install hasn't finished yet

ABORT review finding: ContentBlockerBootstrap's detached install
Task and HomeView's first load race with no ordering guarantee. If
Home wins, isProtectionEnabled reads false with 0 rules and nothing
ever re-checks, producing a permanent false "not enabled" state on
fresh installs. loadWithBootstrapRetry() bounds a short auto-retry
(3 attempts, 500ms apart) so a normal fresh-launch timing hiccup
self-corrects; .refreshable adds pull-to-refresh as the user-facing
escape hatch for anything slower than that window.
EOF
)"
```

---

## Task 7: Wire `RealHomeService` into `AppCompositionRoot` and `ADBLXApp`

**Files:**
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/ADBLXApp.swift`

**Interfaces:**
- Consumes: `RealHomeService(store:)` (Task 5), `AppCompositionRoot.makeFilterStore()` (Task 1), `UIDependenciesConfiguration` (Task 3).
- Produces: `AppCompositionRoot.makeUIDependencies(configuration:store:)` — the `homeService` slot is always `RealHomeService` from this point forward (Home is no longer mockable in any configuration, per the design decision that Home should just work once real); `protectionService`/`subscriptionService`/`settingsService` remain mock until their own Sprint 5B commits.

This is the commit that actually makes the Home tab show real data.

- [ ] **Step 1: Update `makeUIDependencies` to take a `store:` parameter and return `RealHomeService`**

Edit `ADBLX/AppCompositionRoot.swift`, replacing the `UIDependenciesConfiguration`/`makeUIDependencies` block from Task 3 with:

```swift
    /// Selects which set of backend implementations UIDependencies is built from.
    /// `.mock` still exists for SwiftUI previews and any future all-mock testing
    /// path; `homeService` itself is always RealHomeService now that it exists —
    /// Home has no reason to stay mockable once real (Sprint 5A design doc).
    enum UIDependenciesConfiguration {
        case mock
    }

    static func makeUIDependencies(configuration: UIDependenciesConfiguration, store: FilterStore) -> UIDependencies {
        switch configuration {
        case .mock:
            return UIDependencies(
                homeService: RealHomeService(store: store),
                protectionService: MockProtectionService(),
                subscriptionService: MockSubscriptionService(),
                settingsService: MockSettingsService()
            )
        }
    }
```

- [ ] **Step 2: Update `ADBLXApp.swift`'s call site**

Edit `ADBLX/ADBLXApp.swift`, changing:

```swift
        uiDependencies = AppCompositionRoot.makeUIDependencies(configuration: .mock)
```

to:

```swift
        uiDependencies = AppCompositionRoot.makeUIDependencies(configuration: .mock, store: store)
```

(`store` is the same local variable already in scope from Task 2 Step 4's `init`.)

- [ ] **Step 3: Update `RootTabView.swift`'s `#Preview`**

Edit `ADBLX/Navigation/RootTabView.swift:41`, changing:

```swift
#Preview {
    RootTabView(dependencies: AppCompositionRoot.makeUIDependencies(configuration: .mock))
}
```

to:

```swift
#Preview {
    RootTabView(dependencies: AppCompositionRoot.makeUIDependencies(configuration: .mock, store: AppCompositionRoot.makeFilterStore()))
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass. `HomeViewModelTests` still passes because it constructs `HomeViewModel(service: StubHomeService(...))` directly, bypassing `AppCompositionRoot` entirely — the composition-root wiring change doesn't affect it.

- [ ] **Step 6: Manual simulator check — the actual end-to-end verification for this plan**

Open `ADBLX.xcodeproj` in Xcode, run on an iOS Simulator (fresh install/reset the simulator's app data if it has state from a prior run).
Expected: on first launch, `ContentBlockerBootstrap.ensureInitialRulesInstalled` installs the bundled ads snapshot (existing Sprint 1 behavior, unaffected by this plan), which writes to `installed_filters.json`. Navigate to Home: the hero card should show "Active" (protection enabled since at least one group is now installed), the Rules tile should show a real non-zero rule count, the Last Update tile should show a relative time (e.g. "just now"), and the Recent Activity section should show one "Filters Synchronized" entry for the Ads group. This is the first real end-to-end proof that Sprint 5A's wiring works. Unlike the original version of this step, a too-early first read is no longer expected to produce a stuck empty state — Task 6 Step 9's `loadWithBootstrapRetry()` auto-retries up to 3 times over ~1.5s if the first read lands before bootstrap's write; if the tiles are still empty/zero after that window, pull-to-refresh (`.refreshable`, also added in Task 6 Step 9) should populate them. If pull-to-refresh also shows empty state, that's a genuine bug worth investigating (not the timing race this plan was designed to tolerate).

- [ ] **Step 7: Time Profiler check (performance constraint from the design doc)**

In Xcode, use Product → Profile (⌘I) with the Time Profiler template, launch to the Home tab.
Expected: no main-thread stalls over ~16ms during Home's presentation — `RealHomeService.fetchStatus()` is an `actor` method reading a small JSON file via another `actor` (`FilterStore`), so it's already off the main actor by construction; this check confirms no regression.

- [ ] **Step 8: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/AppCompositionRoot.swift ADBLX/ADBLXApp.swift ADBLX/Navigation/RootTabView.swift
git commit -m "$(cat <<'EOF'
feat(home): wire RealHomeService into the composition root

Home tab now displays real installed-filter state instead of mock
data: protection status, rule count, last update, and a
filters-synchronized activity feed all read from
installed_filters.json via FilterStore. Protection, Subscription,
and Settings services remain mock until their own Sprint 5B commits.

Completes Sprint 5A (Commit 1: composition root backend
construction; Commit 2: RealHomeService).
EOF
)"
```

---

## Self-Review Notes

**Spec coverage:**
- Commit 1 (composition root): `ManifestEndpointProvider` ✓ Task 2, `makeHTTPSession()` ✓ Task 2, `makeUpdateCoordinator` ✓ Task 2, `UIDependenciesConfiguration`/rename ✓ Task 3, shared `FilterStore` ✓ Task 1, `ADBLXApp` wiring ✓ Tasks 1-2, zero network at launch ✓ verified in Task 2 Step 4 note.
- Commit 2 (Real HomeService): `HomeStatus` field removal/addition ✓ Task 4, `SafariProtectionStatus` ✓ Task 4, `isProtectionEnabled` semantics ✓ Task 5, `recentActivity` (`.filtersSynchronized` only) ✓ Task 5, group-level `ruleCount` aggregation (no double-counting) ✓ Task 5 + test, Safari/DNS tile copy edits ✓ Task 6, composition root wiring ✓ Task 7, end-to-end manual verification ✓ Task 7 Step 6, performance check ✓ Task 7 Step 7.
- Both design-review addenda (shared `FilterStore` explicit statement, DNS tile ownership-transition note) are reflected in code comments in Tasks 1 and 6 respectively.

**Placeholder scan:** No TBD/TODO left unresolved except the one intentional, documented `// TODO: replace with the real CDN manifest endpoint` in Task 2 — this matches the design spec's own explicit call-out that it's tracked separately and not a Sprint 5 blocker.

**Type consistency:** `HomeStatus` field names (`isProtectionEnabled`, `safariProtectionStatus`, `lastUpdateDescription`, `ruleCount`, `recentActivity`) are identical across Task 4 (definition), Task 5 (`RealHomeService` construction), Task 6 (`HomeView` consumption), and the test files. `AppCompositionRoot.makeFilterStore()`/`makeFilterPipeline(store:)`/`makeUpdateCoordinator(pipeline:store:)`/`makeUIDependencies(configuration:store:)` signatures are consistent from their introduction through every later call site. `UIDependenciesConfiguration.mock` is the only case throughout. `HomeViewModel.loadWithBootstrapRetry(maxAttempts:retryDelay:)` (Task 6 Step 9) is referenced identically in `HomeView.swift`'s `.task` modifier and in the two new `HomeViewModelTests` cases (Task 6 Step 10).

**ABORT review conditions (added 2026-07-22, post-plan-review):**
- **Condition 1 — bootstrap/Home load-order race:** closed by Task 6 Steps 9-13, which add `HomeViewModel.loadWithBootstrapRetry()` (bounded 3-attempt auto-retry) and `.refreshable` pull-to-refresh to `HomeView`, plus two new unit tests proving the retry logic actually stops retrying once `isProtectionEnabled` becomes true and gives up cleanly after `maxAttempts`. Task 7 Step 6's manual check was updated to reflect that a stuck empty state is no longer expected/tolerated.
- **Condition 2 — misleading "Active" tile copy:** closed by changing `home.stat.safari.detail` from "Active" to "Filters Loaded" in Task 6 Steps 1 and 3, with an explicit code comment explaining why "Active" overclaims a live Safari-extension-enabled verification the app cannot perform. (Note: the *hero card's* "Active"/"Inactive" headline, driven by the same `isProtectionEnabled` field, was NOT changed — it predates this plan, is unchanged UI per the Sprint 4 design, and reads less specifically than a "Safari: Active" tile did; revisiting it further was judged out of scope for Sprint 5A and is a candidate for Sprint 5B once real extension-enablement detection exists.)
- **Condition 3 — corrupt/torn read on concurrent write:** addressed by a new atomicity test in Task 5 (`concurrentWriteNeverProducesTornRead`), which found (and the plan now documents) that `FilterStore.writeMetadata`'s existing `.atomic` write option already prevents torn reads at the OS level — this test exists to guard that invariant against regression (e.g., someone later "simplifying" `writeMetadata` to a non-atomic write), not because a fix was needed in `RealHomeService` itself.
- Risk 4 from the ABORT review (cross-suite test fixture collision between `RealHomeServiceTests` and `UpdateCoordinatorTests`, both touching `installed_filters.json` under the same App Group) and Risk 5 (DNS tile em-dash ambiguity) were accepted as-is per the FRB's "acceptable risks" call — not blocking, not addressed by new plan steps. If CI flakiness in `RealHomeServiceTests`/`UpdateCoordinatorTests` appears after this plan ships, that's the first place to look.
