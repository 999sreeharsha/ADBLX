# Sprint 2 — Update Pipeline: Design

## Goal

Sprint 1 delivered the rule pipeline: validate → compile → partition → atomic write →
reload, driven from a bundled snapshot. Sprint 2 builds the infrastructure that feeds
that pipeline from the network instead: fetch a manifest, decide what changed, download
and verify the changed filters, install them transactionally, and roll back cleanly on
failure.

Sprint 2 is not about shipping EasyList. It's about building the update engine that
*happens* to download EasyList once a real manifest exists. `FilterPipeline` itself gets
one small additive change (a deferred-reload mode); nothing else about Sprint 1's
architecture moves.

Maps to PRD FR-03 (manifest fetch), FR-04 (checksum verification), FR-05 (atomic
update + rollback), FR-06 (reload after install).

## Architecture

```
Filtering/
    Models/                        (existing, reused as-is)
        FilterManifest.swift
        InstalledFilter.swift
        FilterMetadata.swift
    Utilities/
        Checksum.swift              extended: verify(fileURL:against:) throws
    Storage/
        FilterStore.swift           extended: Directory.previousCompiled, .previousMetadata
    Pipeline/
        FilterPipeline.swift        extended: install(..., reloadStrategy:)
    Deployment/
        ReloadCoordinator.swift     unchanged
    Updates/                        (new, flat — matches sibling folder convention)
        HTTPSession.swift           protocol wrapping URLSession.data(for:)
        ManifestClient.swift        fetch manifest.json, ETag / If-None-Match / 304
        FilterDownloadClient.swift  download one filter body to a temp file
        ManifestStore.swift         persist/load cached manifest + ETag (via FilterStore)
        UpdatePlanner.swift         pure: (FilterManifest, [InstalledFilter]) -> UpdatePlan
        UpdateCoordinator.swift     orchestrates the full update transaction
```

Nothing in `Models/` or `Utilities/` is duplicated. `Updates/` contains only the new
orchestration responsibility: turning a remote manifest into calls against the existing
`FilterPipeline` and `FilterStore`.

## Components

### `FilterManifest` (existing, unchanged)

Stays exactly as defined in Sprint 1 — no ETag field. ETag is HTTP transport metadata,
not part of what the manifest *means*, and doesn't belong on a type that might one day
be loaded from a bundle, disk fixture, or import flow instead of the network.

### `ManifestStore` (new)

Persists the cached manifest and its ETag as sibling concerns, not one merged type:

```swift
struct CachedManifest: Codable {
    var manifest: FilterManifest
    var etag: String?
}

actor ManifestStore {
    init(filterStore: FilterStore)
    func load() throws -> CachedManifest?
    func save(_ manifest: FilterManifest, etag: String?) throws
}
```

Backed by `FilterStore`'s `Metadata` directory (`manifest.json`), consistent with how
`installed_filters.json` and `statistics.json` are already persisted.

### `HTTPSession` (new)

```swift
protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
extension URLSession: HTTPSession {}
```

Lets `ManifestClient`/`FilterDownloadClient` be unit-tested with a mock conforming to
this protocol — no `URLProtocol` stubbing, no real network in CI.

### `ManifestClient` (new)

```swift
actor ManifestClient {
    init(session: HTTPSession, endpoint: URL)
    func fetch(previousETag: String?) async throws -> ManifestFetchResult
}

enum ManifestFetchResult {
    case notModified
    case updated(FilterManifest, etag: String?)
}
```

Sends `If-None-Match` when a previous ETag exists. A 304 short-circuits the whole update
run with no further work. A non-2xx/304 status throws.

### `FilterDownloadClient` (new)

```swift
struct DownloadedFilter {
    var filterID: String
    var tempFileURL: URL
    var expectedChecksum: String
    var version: String
}

actor FilterDownloadClient {
    init(session: HTTPSession)
    func download(_ entry: FilterManifest.Entry) async throws -> DownloadedFilter
}
```

Streams the response body to a temp file (App Group temp scratch space) rather than
buffering in memory. Does not verify or install — purely fetch-and-locate-on-disk.

### `Checksum` (existing, extended)

```swift
enum Checksum {
    static func sha256Hex(of data: Data) -> String            // existing, unchanged
    static func verify(fileURL: URL, against expectedHex: String) throws  // new
}

enum ChecksumError: Error { case mismatch(expected: String, actual: String) }
```

`verify` reads the file itself (today via `Data(contentsOf:)`, swappable for streaming
later) so callers holding a `URL` from `FilterDownloadClient` never need to load the
whole file into memory just to pass it to this call.

### `UpdatePlanner` (new)

Pure function, no I/O, no async — the easiest thing in this sprint to test exhaustively.

```swift
enum UpdateAction {
    case install(FilterManifest.Entry)   // new or changed version
    case remove(filterID: String)        // present locally, absent from manifest
    case keep(filterID: String)          // unchanged, no action needed
}

struct UpdatePlan {
    var actions: [UpdateAction]
}

enum UpdatePlanner {
    static func plan(manifest: FilterManifest, installed: [InstalledFilter]) -> UpdatePlan
}
```

Comparison is by `(id, version, checksumSHA256)` against the matching `InstalledFilter`.
Premium-gated entries the user hasn't unlocked are excluded from `.install` up front
(Sprint 2 has no StoreKit — treat all `premium: true` entries as `.keep`/no-op for now,
since there's nothing to gate against yet; this is revisited when StoreKit lands).

### `FilterPipeline` (existing, additive change only)

```swift
enum ReloadStrategy { case immediate, case deferred }

func install(
    filterID: String,
    source: Data,
    reloadStrategy: ReloadStrategy = .immediate
) async throws -> PipelineResult
```

Default preserves Sprint 1 behavior exactly — `installBundledSnapshotIfNeeded()` and any
other existing caller are unaffected. When `reloadStrategy == .deferred`, `install`
performs validate→compile→partition→write→persist-metadata but skips the
`ReloadCoordinator` call; `reloadResults` on the returned `PipelineResult` is empty in
that case. `UpdateCoordinator` is responsible for the one reload call per batch.

### `FilterStore` (existing, extended)

Adds a way to snapshot and restore the store's entire mutable state, mirroring the
existing directory layout rather than tracking individual files:

```swift
extension FilterStore.Directory {
    // existing: .filters, .compiled, .metadata
}

actor FilterStore {
    // existing methods unchanged
    func snapshotForRollback() throws -> RollbackSnapshot
    func restore(_ snapshot: RollbackSnapshot) throws
}

struct RollbackSnapshot {
    // opaque to callers; internally a copy of Compiled/ and Metadata/
    // (installed_filters.json, statistics.json, manifest.json) at snapshot time
}
```

`snapshotForRollback()` copies the current `Compiled/` and `Metadata/` directories to a
`Previous/` root (`Previous/Compiled/`, `Previous/Metadata/`) before any writes in a
batch begin. `restore(_:)` replaces `Compiled/` and `Metadata/` with the snapshot's
contents and removes the `Previous/` copy. This is "restore the entire mutable state
`FilterStore` owns," not a hand-maintained list of filenames — new files added to either
directory in future sprints are covered automatically.

### `UpdateCoordinator` (new)

```swift
actor UpdateCoordinator {
    init(
        manifestClient: ManifestClient,
        manifestStore: ManifestStore,
        downloadClient: FilterDownloadClient,
        pipeline: FilterPipeline,
        store: FilterStore,
        reloader: ReloadCoordinator
    )
    func run() async throws -> UpdateRunResult
}

enum UpdateRunResult {
    case upToDate
    case updated(installedFilterIDs: [String], reloadResults: [ReloadCoordinator.ReloadResult])
    case rolledBack(reason: Error)
}
```

## Data flow

```
UpdateCoordinator.run()
  cached = manifestStore.load()
  result = manifestClient.fetch(previousETag: cached?.etag)
    .notModified            → return .upToDate
    .updated(manifest, tag) → continue

  plan = UpdatePlanner.plan(manifest: manifest, installed: currentInstalledFilters)
  installs = plan.actions.compactMap { if case .install(let e) = $0 { e } }
  if installs.isEmpty → manifestStore.save(manifest, etag: tag); return .upToDate

  downloaded = try await installs.map { try await downloadClient.download($0) }
  for filter in downloaded {
      try Checksum.verify(fileURL: filter.tempFileURL, against: filter.expectedChecksum)
  }
  // all downloads verified before any write touches Compiled/ or Metadata/

  snapshot = try store.snapshotForRollback()
  // extension IDs derived from the union of groups touched by the batch, mapped through
  // the same group→extension-bundle-ID mapping RulePartitioner already owns
  affectedExtensionIDs = extensionIDs(for: downloaded)
  do {
      for filter in downloaded {
          let data = try Data(contentsOf: filter.tempFileURL)
          _ = try await pipeline.install(filterID: filter.filterID, source: data, reloadStrategy: .deferred)
      }
      try manifestStore.save(manifest, etag: tag)
      let reloadResults = await reloader.reload(extensionIdentifiers: affectedExtensionIDs)
      return .updated(installedFilterIDs: downloaded.map(\.filterID), reloadResults: reloadResults)
  } catch {
      try store.restore(snapshot)
      _ = await reloader.reload(extensionIdentifiers: affectedExtensionIDs)  // reload previous state back in
      return .rolledBack(reason: error)
  }
```

Checksum verification happens before the snapshot/write phase begins — a bad download
never touches on-disk state at all, so rollback is only needed for failures during
`install()` itself (compile/partition/write errors) or metadata persistence.

## Error handling

- **Manifest fetch fails** (network, non-2xx) → `run()` throws before any local state is
  touched. Previous manifest/ETag stay cached for the next attempt.
- **Checksum mismatch** on any downloaded filter → whole run aborts before the snapshot
  phase; nothing installed changes. No partial batch.
- **`install()` fails** for any filter in the batch (validation/compile/partition/write
  error) → `store.restore(snapshot)` puts `Compiled/` and `Metadata/` back exactly as
  they were, one reload fires to make Safari re-pick-up the restored state, and
  `.rolledBack` is returned with the underlying error.
- **Reload fails** after a successful commit → files stay committed (reload is
  best-effort against Safari, not part of the write transaction); per-extension
  `ReloadResult` failures are surfaced in `.updated`, same as Sprint 1's existing
  behavior for `PipelineResult.reloadResults`.

## Out of scope for Sprint 2

Same exclusions as originally scoped: Filters UI, annoyances enable/disable UI, regional
selection, StoreKit (premium entries are inert no-ops this sprint — no purchase flow
exists to gate them), Packet Tunnel, Safari Web Extension, `BGAppRefreshTask` /
background scheduling, silent push, iCloud sync. `UpdateCoordinator.run()` is written to
be callable from either a foreground trigger or a future background scheduler, but no
scheduler is built this sprint.

## Testing

All unit-level, no real network or server (per the DI decision above):

- **`UpdatePlanner`**: pure function — new filter, changed version/checksum, removed
  filter, unchanged filter, premium entry (inert), empty manifest, empty installed list.
- **`ManifestClient`**: mocked `HTTPSession` — 200 with valid JSON, 304, 404, 500,
  malformed JSON body, request timeout, ETag header round-trip.
- **`FilterDownloadClient`**: mocked `HTTPSession` — success writes expected bytes to a
  temp file, non-2xx throws, network error throws.
- **`Checksum.verify`**: matching hash passes, mismatched hash throws
  `ChecksumError.mismatch`.
- **`FilterStore.snapshotForRollback`/`restore`**: snapshot then mutate then restore
  reproduces exact prior byte content of `Compiled/` and `Metadata/`.
- **`FilterPipeline.install(reloadStrategy:)`**: `.immediate` behaves identically to
  Sprint 1's existing tests; `.deferred` skips the reload call and returns empty
  `reloadResults`.
- **`UpdateCoordinator`**: end-to-end with mocked `HTTPSession` and an injectable
  filesystem failure (matching the `AtomicFilesystem`/`FailingFilesystem` pattern already
  used in `AtomicRuleWriterTests`) to prove: up-to-date short-circuit on 304, full
  successful multi-filter update commits once and reloads once, and a mid-batch install
  failure triggers a full rollback restoring prior `Compiled/`/`installed_filters.json`
  bytes exactly with exactly one reload call.

Target: 55-70 tests total across these components, consistent with the original sprint
estimate.

## Acceptance criteria

1. Fetch `manifest.json` from a configurable endpoint via `ManifestClient`.
2. Respect `ETag` and correctly short-circuit on `304 Not Modified`.
3. Download only changed filter lists, per `UpdatePlanner`'s diff against
   `InstalledFilter`.
4. Verify every downloaded file's SHA-256 via `Checksum.verify` before any install call.
5. Feed verified filters into the existing `FilterPipeline.install(...)` API without
   modifying its Sprint 1 behavior for existing callers.
6. Preserve the previous compiled rules and metadata, and roll back the entire batch if
   any install in the run fails.
7. Comprehensive unit-test coverage for `UpdatePlanner`, `Checksum.verify`,
   `FilterStore` snapshot/restore, and `UpdateCoordinator`'s commit/rollback paths.
