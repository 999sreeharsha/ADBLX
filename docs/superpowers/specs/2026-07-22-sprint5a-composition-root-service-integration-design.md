# Sprint 5A — Composition Root & Service Integration

## Goal

Connect the existing backend (`FilterPipeline`, `UpdateCoordinator`, `FilterStore`,
`InstalledFilter` metadata) to the existing UI by replacing mock UI services with
real ones, one commit at a time, behind the protocols established in Sprint 4.

No redesigns. No new UI. No protocol changes unless a real backend gap forces one
(documented explicitly where that happens — see Commit 2).

```
SwiftUI View → ViewModel → Feature Service Protocol → Real Service → Filtering Backend
```

replaces

```
SwiftUI View → ViewModel → Feature Service Protocol → Mock Service
```

Sprint 5 is split into two phases to keep commits small and reviewable:

- **Sprint 5A** (this spec) — composition root + dependency injection wiring, and
  the first two real services (Home, and enough backend construction to support
  every later commit).
- **Sprint 5B** — remaining feature-by-feature live data (Protection, Advanced
  Filter Lists, Update Progress, Settings, About), scoped at a sketch level below
  and refined further during that sprint's own brainstorming/planning pass.

## Out of scope (all of Sprint 5)

StoreKit, DNS Packet Tunnel, VPN management, Safari Web Extension, background
refresh, push-triggered updates. These are separate architectural areas.

## Current state (verified against code, 2026-07-22)

- `AppCompositionRoot` (enum) constructs `FilterPipeline` via `makeFilterPipeline()`
  and returns mock UI services via `makeMockUIDependencies()`.
- `UpdateCoordinator` is **not constructed anywhere in the app** — it exists only
  as a type exercised by `UpdateCoordinatorTests.swift`, built inline with test
  doubles. Sprint 5A is the first time it's wired into the running app.
- No real CDN manifest endpoint exists anywhere in the codebase.
  `ManifestClient.endpoint` is an arbitrary injected `URL` with no production
  value configured.
- `AboutView` is fully static text today — no service, no ViewModel.
- `UpdateProgressModel.start()` walks a canned local sequence of
  `.checking → .downloading → .installing → .complete` with fixed sleeps; its own
  doc comment already anticipates replacing the body with real
  `UpdateCoordinator` calls without changing the sheet.
- `UpdateCoordinator.run()` is a single `async throws -> UpdateRunResult` call —
  it does not emit intermediate progress events. Mapping it onto
  `UpdatePhase`'s four in-flight cases is a known open question for Commit 5
  (see below).

## Commit 1 — Composition root completes backend construction

`AppCompositionRoot` stays an `enum` (stateless factory namespace) — this is not
an ownership-model change. `ADBLXApp` continues to hold the single long-lived
instances as stored properties, exactly as it already does for `filterPipeline`.

New factory methods on `AppCompositionRoot`:

```swift
protocol ManifestEndpointProvider: Sendable {
    var manifestURL: URL { get }
}

struct AppManifestEndpointProvider: ManifestEndpointProvider {
    let manifestURL = URL(string: "https://example.invalid/manifest.json")!
    // TODO: replace with real CDN endpoint once available (tracked separately;
    // not a Sprint 5 blocker — see Commit 5's honest-failure behavior).
}
```

- `makeHTTPSession() -> HTTPSession` — the one place a networking transport is
  constructed; `ManifestClient` and `FilterDownloadClient` both receive it as a
  shared instance instead of each reaching for `URLSession.shared`.
- `makeUpdateCoordinator(pipeline: FilterPipeline, store: FilterStore) -> UpdateCoordinator`
  — internally builds `ManifestClient`, `ManifestStore`, `FilterDownloadClient`,
  and `AppManifestEndpointProvider`, hiding all of that from `ADBLXApp`.
- `makeUIDependencies(configuration: UIDependenciesConfiguration, pipeline:, updateCoordinator:, store:) -> UIDependencies`
  replaces `makeMockUIDependencies()`.
  ```swift
  enum UIDependenciesConfiguration {
      case mock
  }
  ```
  Only `.mock` exists in Commit 1 — no behavior changes yet, `UIDependencies`
  still returns every mock service. The enum exists purely so Commit 1 doesn't
  need a rename later when `.production` is added; `.mock` is the only case
  until Sprint 5B needs otherwise.

`ADBLXApp` changes to store `updateCoordinator` alongside its existing
`filterPipeline` property and pass both into `makeUIDependencies(.mock, ...)`.
No view or view-model changes. `UpdateCoordinator` is constructed but never
invoked — no network activity at launch.

**Acceptance criteria:**
- `AppCompositionRoot` is the sole place any backend type is constructed.
- Exactly one `FilterPipeline` and one `UpdateCoordinator` instance exist,
  owned by `ADBLXApp`.
- `UIDependencies` still returns all-mock services; zero visual change.
- Existing test suite passes unmodified (tests construct their own inline
  dependencies per the existing convention — this commit doesn't touch that).

## Commit 2 — Real HomeService

`HomeStatus` changes shape to only expose values the backend can honestly
support:

- **Remove** `blockedPercentage: Double` — no tracker/ad-block telemetry exists
  anywhere in the pipeline; Safari Content Blockers are declarative with no
  block-event callback to the app. Fabricating or heuristically estimating this
  number was rejected as inconsistent with the product's privacy-first
  positioning.
- **Remove** `dnsProviderName: String` — belongs to DNS Packet Tunnel, out of
  scope for all of Sprint 5.
- **Add** `safariProtectionStatus: SafariProtectionStatus` where
  `enum SafariProtectionStatus { case active }` — only `.active` is implemented
  now; `.needsSetup`/`.unavailable` are reserved for a future sprint once
  Safari extension-enablement detection exists (relates to onboarding FR-07,
  not built yet).
- `isProtectionEnabled: Bool` — becomes `true` iff `installed_filters.json`
  has at least one entry. This is real backend state ("has the pipeline
  successfully deployed anything") but is **not** the same concept as a future
  user-facing on/off toggle. Document this semantic distinction on the property
  itself: Commit 3's `ProtectionService` work will change what feeds this value
  without changing `HomeStatus`'s shape or `HomeView`.
- `recentActivity: [HomeActivityEntry]` — `RealHomeService` emits one
  `.filtersSynchronized` entry per `FilterGroup` present in
  `installed_filters.json`, using that group's `lastUpdated`, sorted newest
  first. `.trackerBlocked` and `.protectionToggled` cases stay defined on
  `HomeActivityEntry.Kind` for future use but nothing produces them yet
  (`.protectionToggled` becomes producible once Commit 3 persists toggle
  state).
- `ruleCount: Int` — sum/aggregate from `installed_filters.json`, consistent
  with the existing group-level-only constraint documented in
  `docs/gotchas.md`.
- `lastUpdateDescription: String` — derived from the most recent `lastUpdated`
  across all installed groups.

**Minimal, justified UI edits** (not a redesign — copy-only, same layout):
- Safari tile detail line: replace the `String(format:)`-interpolated
  percentage with a static localized "Active" string reflecting
  `safariProtectionStatus`.
- DNS tile: becomes a view-owned static localized "Not configured" placeholder
  with no backing `HomeStatus` field — DNS state has no real source until the
  Packet Tunnel subsystem exists in a later sprint.

`RealHomeService` reads `installed_filters.json` via `FilterStore.read(_:in:)`,
already actor-isolated/async — no synchronous main-thread I/O.

**Acceptance criteria:**
- No fabricated or heuristic values anywhere in `HomeStatus`.
- `AppCompositionRoot.makeUIDependencies` returns `RealHomeService` for the
  `homeService` slot; Protection/Settings/Subscription stay mock until their
  own commits. Whether this is unconditional under `.mock` (Home is simply no
  longer mockable once real) or gated behind a new configuration case is an
  implementation-planning decision for Commit 2, not fixed by this spec.
- `HomeViewModelTests` mock-based tests continue to pass unmodified; new tests
  cover `RealHomeService` directly against a real (test App Group)
  `FilterStore`, including the empty-`installed_filters.json` case
  (`isProtectionEnabled == false`, empty activity feed).

## Commits 3–7 (Sprint 5B) — sketch level only

These are scoped here to establish direction and known constraints; each gets
refined during Sprint 5B's own planning pass rather than fully specified now.

### Commit 3 — Real ProtectionService

Wires `InstalledFilterStore`/`installed_filters.json`, `FilterGroup` metadata,
and `FilterPipeline` state into `ProtectionCategory`/`FilterListEntry`.

Known constraint: no per-category or per-filter-list enable/disable state is
persisted anywhere in the backend today. This commit must introduce that
persistence (likely a small JSON-backed store alongside `installed_filters.json`
in `FilterStore`'s `Metadata/` directory) — this is new backend surface, not
pure wiring, and should be scoped carefully to avoid growing into its own
sprint. Once persisted, this is also what lets Commit 2's `isProtectionEnabled`
gain real toggle semantics (see Commit 2 note above) and what lets
`.protectionToggled` activity entries start being emitted.

Per `docs/gotchas.md`, `FilterListEntry` must not display a fabricated
per-source rule count — `InstalledFilter.ruleCount` is group-level only.

### Commit 4 — Real Advanced Filter Lists

Uses manifest metadata, `InstalledFilter` metadata, and `GroupComposition`.
Same group-level-rule-count constraint as Commit 3 applies. Depends on whatever
enable/disable persistence Commit 3 introduces.

### Commit 5 — Update Progress

Replaces `UpdateProgressModel.start()`'s canned sleep sequence with real
`UpdateCoordinator.run()` calls, per that type's own doc comment.

Known open question: `UpdateCoordinator.run()` is one atomic
`async throws -> UpdateRunResult` call with no intermediate progress
callbacks, but `UpdatePhase` has four in-flight cases
(`.checking/.downloading/.installing/.complete`). Options to resolve during
Sprint 5B planning: collapse to fewer displayed phases, add a lightweight
progress callback to `UpdateCoordinator` (a "protocol change" the sprint goal
says to avoid unless necessary — would need explicit justification), or accept
a coarser progress indicator that jumps between fewer states.

Given no real CDN manifest endpoint exists (Commit 1), a live update check will
fail. Per the earlier design decision: **show an honest "Unable to check for
updates" error state** (using `UpdatePhase.failed`) rather than simulating
progress. This is more truthful than fake progress and requires no special-
casing — it's simply what a real network failure produces.

### Commit 6 — Settings

Persists automatic-updates, filter options, and diagnostics toggles through
`FilterStore`'s existing storage layer instead of in-memory mock state, mirroring
the `MockSettingsService`/`SettingsSnapshot` shape already established.

### Commit 7 — About

`AboutView` is currently fully static text with no service or ViewModel at all
— this commit is new wiring, not a mock-to-real swap. Needs: app version/build
number (from `Bundle.main`), installed filter version and compiled rule
statistics (from `installed_filters.json` / `statistics.json` via `FilterStore`,
the same metadata Commit 2 already reads for Home).

## Performance & battery

Unchanged from the original brief — this sprint is primarily reads of small,
already-maintained metadata files plus one-time object construction at launch:

- **Main thread:** backend reads stay asynchronous; no synchronous disk I/O on
  the main actor.
- **Memory:** one shared instance each of `FilterPipeline`, `UpdateCoordinator`,
  `HTTPSession`, and supporting actors — no duplicate caches.
- **Disk I/O:** `installed_filters.json`/`statistics.json`/manifest cache read
  on demand; no repeated reads during view updates.
- **Network:** zero at launch — `UpdateCoordinator` is constructed but idle
  until explicitly invoked (Commit 5).
- **Background execution:** no changes.

Verify with Time Profiler (no main-thread stalls >~16ms on Home/Protection
presentation), Allocations (no duplicate backend instances), and Energy Log
(opening Home/Protection triggers no unnecessary work).

## Testing

Existing tests construct dependencies inline (mocks or real backend test
doubles) rather than through `AppCompositionRoot` — this convention is
unchanged by Sprint 5A. New tests for `RealHomeService` follow the same
pattern used by `UpdateCoordinatorTests`/`FilterPipelineTests`: real `FilterStore`
pointed at the test App Group, asserting against actual `installed_filters.json`
content.
