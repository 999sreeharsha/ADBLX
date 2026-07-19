# Sprint 3A — Group Composition: Design

## Goal

Sprint 3A is not about adding more filters. It's about changing the fundamental
unit of compilation from "one filter" to "one `FilterGroup`, composed from N
filters."

Today the pipeline thinks:

```
Filter → Compile → Partition → Ads.json
```

After Sprint 3A it thinks:

```
FilterGroup (Ads) ← EasyList, Peter Lowe, ADBLX Proprietary, ...
        ↓
     Compose
        ↓
     Compile
        ↓
     Partition
        ↓
     Ads.json
```

This directly retires the two "known dependency" limitations Sprint 2 documented
and deferred:

- **`.unsupportedGroup`** existed because `RulePartitioner` could only route
  `.ads`. Sprint 3A's partitioner (Commit 3) maps every `FilterGroup` to an
  extension identifier, so the case can't fire and is removed.
- **`.groupConflict`** existed because `FilterPipeline.install()` could only
  accept one source per call, so a second `.ads`-group install in the same plan
  was a genuine conflict. Sprint 3A's composition (Commits 1-2, 4) makes "many
  filters, one group, one install call" the normal case, so the case can't fire
  and is removed.

Maps to PRD FR-02 (multi-filter composition per group), and completes the
group-routing scope FR-01 originally described.

## Architecture

```
Filtering/
    Models/
        FilterSource.swift            (new — Commit 1)
        GroupComposition.swift        (new — Commit 1)
        ComposedRules.swift           (new — Commit 2)
        CompiledRuleSet.swift         (changed — Commit 2: sourceFilterID → group)
        InstalledFilter.swift         (unchanged — already an array/metadata concept)
    Compilation/
        CompositionService.swift      (new — Commit 2)
        RuleCompiler.swift            (changed — Commit 2: drop filterID param)
    Deployment/
        RulePartitioner.swift         (changed — Commit 3: GroupPartitioner replaces
                                        PassthroughAdsPartitioner)
    Pipeline/
        FilterPipeline.swift          (changed — Commit 4: install(composition:) replaces
                                        install(filterID:source:...))
    Updates/
        UpdatePlan.swift              (changed — Commit 5: UpdateAction.install(group:entries:)
                                        replaces per-filter .install/.unsupportedGroup/.groupConflict)
        UpdateCoordinator.swift       (changed — Commit 5: download+compose per group)
```

### Data flow (steady state, post-Sprint-3A)

```
FilterManifest.Entry (N entries, mixed groups)
        ↓  UpdatePlanner.plan(): diff against installed, THEN group by FilterGroup
UpdateAction.install(group: FilterGroup, entries: [FilterManifest.Entry])   -- one per group, pure/no I/O
        ↓  UpdateCoordinator.run()
for each install action:
    download + verify checksum for every entry in that group  → [FilterSource]
    GroupComposition(group, sources: [FilterSource])            -- manifest order preserved
        ↓
    FilterPipeline.install(composition, reloadStrategy: .deferred)
        ↓  CompositionService.compose(sources:)
    ComposedRules(group, data, sourceCount, ruleCount)          -- decode each source's JSON
                                                                    array, concatenate in the
                                                                    order given, re-encode once
        ↓  RuleCompiler.compile(source: composed.data, group: composed.group)
    CompiledRuleSet(group, rawJSON, ruleCount, statistics)
        ↓  GroupPartitioner.partition(_, group:)
    PartitionedRules(extensionIdentifier, group, json, ruleCount)  -- one per group, total mapping
        ↓  AtomicRuleWriter
    Compiled/<Group>.json                                        -- written once per group, not
                                                                     once per filter
        ↓
    installed_filters.json merged: one entry per FilterSource (by id), same
    accumulate-by-id logic Sprint 2 already has, now looping over composition.sources
after all groups install successfully:
    manifestStore.save(manifest, etag)
    reload only the extensions for groups that had an install action  -- one reload per
                                                                          affected extension,
                                                                          not per source filter
on any failure: store.restore(snapshot) — whole Compiled/+Metadata tree, unchanged from
Sprint 2 — rolls back every group's writes in the batch, not just the failing one
```

### Ordering is caller-owned, end to end, never re-sorted

Manifest order is the single source of truth for composition order. No layer
reorders:

```
FilterManifest.entries (source order)
        ↓ preserved by UpdatePlanner's per-group Entry lists
        ↓ preserved by UpdateCoordinator's per-entry download loop
        ↓ preserved by GroupComposition.sources
        ↓ preserved by CompositionService (concatenates arrays in the order given)
```

"Deterministic" means: the same `GroupComposition` (same sources, same order)
compiled twice produces byte-identical `Compiled/<Group>.json`. It does **not**
mean different orderings converge to the same output — order is meaningful and
preserved, not canonicalized.

### Grouping is by key, not position

`UpdatePlanner` groups via `Dictionary<FilterGroup, [FilterManifest.Entry]>`
(built by iterating `manifest.entries` once, appending each `.install`-eligible
entry to its group's bucket in the order encountered). Entries for the same
group do not need to be adjacent in the manifest.

## Component changes

### Commit 1 — Composition models

New, in `Filtering/Models/`:

```swift
struct FilterSource: Equatable {
    var filterID: String
    var group: FilterGroup
    var version: String
    var checksumSHA256: String
    var data: Data
}

struct GroupComposition: Equatable {
    var group: FilterGroup
    var sources: [FilterSource]   // order is authoritative — see "Ordering" above
}
```

Pure data types. No compiler, partitioner, or pipeline changes. Existing tests
unchanged; new tests cover construction and equality only.

**Acceptance criteria**
- Existing tests unchanged.
- `FilterSource`/`GroupComposition` fully unit tested (construction, `Equatable`).
- No runtime behavior changes — nothing else references these types yet.

### Commit 2 — CompositionService + compiler drops per-filter identity

`RuleCompiler`'s current stub (`PassthroughRuleCompiler`) already assumes its
`source: Data` is a valid Safari content-blocker JSON array — it's a passthrough
that validates and counts, not a text parser (real EasyList parsing arrives with
the SafariConverterLib swap post ADR-0001). Composition therefore happens at the
JSON-array level, not raw byte concatenation, which would produce two
concatenated JSON documents (invalid JSON).

New `Filtering/Models/ComposedRules.swift`:

```swift
struct ComposedRules: Equatable {
    var group: FilterGroup
    var data: Data          // re-encoded, single JSON array
    var sourceCount: Int
    var ruleCount: Int      // sum of decoded array lengths, pre-compile
}
```

New `Filtering/Compilation/CompositionService.swift`:

```swift
protocol CompositionService: Sendable {
    nonisolated func compose(_ sources: [FilterSource], group: FilterGroup) throws -> ComposedRules
}
```

Decodes each source's `data` as a JSON array, concatenates the decoded arrays
in the order given, re-encodes once. No I/O — pure transform, same
`nonisolated`/nonstateful shape as `RuleCompiler` and `RulePartitioner`.

`RuleCompiler` changes shape to match: it no longer receives or needs a
`filterID` (there is no longer a single source filter once composition has run
— manufacturing a synthetic id like `"ads-composition"` would misrepresent an
identity that doesn't exist at this layer). New signature:

```swift
protocol RuleCompiler: Sendable {
    nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet
}
```

`CompiledRuleSet.sourceFilterID: String` is replaced with `group: FilterGroup`.
Per-filter identity (id, version, checksum) continues to live where it already
lives correctly: `InstalledFilter`, one entry per source filter in
`installed_filters.json`.

**Acceptance criteria**
- Multiple `FilterSource`s for one group compose into one `ComposedRules`.
- Source ordering is deterministic (see "Ordering" above).
- Composing the same ordered sources twice gives byte-identical `ComposedRules.data`.
- `RuleCompiler`/`CompiledRuleSet` updated; existing Sprint 1/2 compiler tests
  updated to the new signature, no behavior change for single-source callers.

### Commit 3 — Real partitioner

Replace `PassthroughAdsPartitioner` with `GroupPartitioner`, constructed with a
total `[FilterGroup: String]` mapping (all four bundle IDs already exist in the
Xcode project: `com.ADBLX.ADBLX.AdsBlocker`, `.PrivacyBlocker`,
`.AnnoyancesBlocker`, `.RegionalBlocker`). `AppCompositionRoot` gains this
mapping alongside (replacing) the single `adsExtensionIdentifier` constant.

```swift
protocol RulePartitioner: Sendable {
    nonisolated func partition(_ ruleSet: CompiledRuleSet, group: FilterGroup) async throws -> PartitionedRules
}
```

Returns one `PartitionedRules`, not an array — a `CompiledRuleSet` now
corresponds to exactly one group by construction (it came from one
`GroupComposition`), so there's nothing left to fan out. The 150K-rule budget
check moves here unchanged, keyed by the mapping's total coverage rather than a
hardcoded `.ads` case.

**Acceptance criteria**
- Every `FilterGroup` maps to exactly one extension identifier (`GroupPartitioner`
  is constructed with a total mapping — unmapped groups are a compile-time/init-time
  impossibility, not a runtime guard).
- Existing Ads behavior preserved (same extension identifier, same budget limit).
- `RulePartitionerError.ruleBudgetExceeded` still fires per group.

### Commit 4 — Pipeline unifies on GroupComposition

`FilterPipeline.install(filterID:source:version:reloadStrategy:)` is deleted.
Single new entry point:

```swift
func install(_ composition: GroupComposition, reloadStrategy: ReloadStrategy = .immediate) async throws -> PipelineResult
```

Sequence: `CompositionService.compose(composition.sources, group: composition.group)`
→ `RuleCompiler.compile(source:group:)` → `GroupPartitioner.partition(_:group:)`
→ atomic write to `Compiled/<Group>.json` (once — this is what naturally
resolves the overwrite problem, since there's now exactly one write per group
per call, not one write per filter racing another) → for each
`composition.sources` entry, merge an `InstalledFilter` into
`installed_filters.json` (same remove-by-id-then-append accumulation Sprint 2
already implemented, now looped) → reload per `reloadStrategy`.

`installBundledSnapshotIfNeeded()` migrates to build a one-source
`GroupComposition(group: .ads, sources: [FilterSource(filterID: "ads-bundled", ...)])`
and call the same method — no parallel path.

**Acceptance criteria**
- One `install()` call installs an entire group's composition in one pass.
- `Compiled/<Group>.json` is written exactly once per call, regardless of
  `composition.sources.count`.
- `installed_filters.json` ends up with one entry per source filter after the
  call (existing accumulate-by-id semantics, unchanged).
- `installBundledSnapshotIfNeeded()` uses the same code path; no second install
  method exists on `FilterPipeline`.

### Commit 5 — UpdatePlanner + UpdateCoordinator

`UpdateAction` changes:

```swift
enum UpdateAction: Equatable {
    case install(group: FilterGroup, entries: [FilterManifest.Entry])
    case remove(filterID: String)
    case keep(filterID: String)
    case skipPremium(FilterManifest.Entry)
}
```

`.unsupportedGroup` and `.groupConflict` are removed — both are structurally
impossible once every group routes (Commit 3) and multiple entries per group
become one grouped action instead of N competing per-filter actions.

`UpdatePlanner.plan()`: first diff each manifest entry against `installed` (by
id, on `(version, checksumSHA256)`) exactly as today, classifying into
install-eligible / keep / skipPremium; entries no longer installed are still
walked for `.remove` exactly as today. Then bucket install-eligible entries into
`Dictionary<FilterGroup, [FilterManifest.Entry]>` (insertion order preserved per
bucket) and emit one `.install(group:entries:)` action per non-empty bucket.

`UpdateCoordinator.run()`: for each `.install(group, entries)` action, download
and checksum-verify every entry (existing `FilterDownloadClient`/`Checksum`
logic, now looped per group instead of per plan), build a `GroupComposition`,
call `pipeline.install(composition, reloadStrategy: .deferred)`. Track which
groups had a successful install; after all groups complete, `reload` only
those groups' extension identifiers via the existing
`GroupPartitioner`'s mapping (`AppCompositionRoot`) — one reload per affected
extension, not per source filter, matching today's behavior. Rollback path
(`store.snapshotForRollback()`/`restore()`) is untouched — it already snapshots
the whole `Compiled/`+`Metadata/` tree, so a failure on group 3 of 4 still
rolls back everything, exactly as it does today for a single group.

**Acceptance criteria**
- `.unsupportedGroup` and `.groupConflict` no longer exist anywhere in the codebase.
- A manifest with entries across all four groups produces at most one
  `.install` action per group, each carrying every install-eligible entry for
  that group.
- `UpdateCoordinator` installs one `GroupComposition` per affected group; existing
  rollback and checksum guarantees are exercised by tests unchanged from Sprint 2's
  suite, extended to multi-group scenarios.
- Reload happens once per affected extension identifier, not once per filter.

## Performance & Battery

**Main thread** — composition, compilation, and partitioning remain off the
main actor (same `nonisolated`/actor-isolated boundaries as Sprint 1/2); no UI
work changes.

**Memory** — `UpdateCoordinator` processes one group's download → compose →
install sequence at a time (already the natural shape of the `for` loop over
install actions); at most one group's decoded source arrays are resident at
once, keeping compilation under the PRD's <200MB target.

**Disk I/O** — only the final compiled JSON is written atomically, once per
group. No intermediate composed files are written to disk (composition is
in-memory `Data` → `Data`).

**Network** — unchanged from Sprint 2.

**Battery** — composition work (JSON decode/concatenate/encode) is small
relative to download and compile time; reload count is unchanged in shape (once
per affected extension), so no new reload-driven battery cost.

## Acceptance criteria for Sprint 3A

- Multiple source lists compose into a single compiled output per `FilterGroup`.
- All four content blocker groups (`Ads`, `Privacy`, `Annoyances`, `Regional`) are routable.
- `Compiled/*.json` is generated once per group rather than once per filter.
- `.unsupportedGroup` and `.groupConflict` are both removed from the planner.
- `UpdateCoordinator` installs grouped compositions instead of individual filters.
- Existing rollback and checksum guarantees from Sprint 2 remain intact.
- `FilterPipeline` exposes exactly one install method (`install(_:reloadStrategy:)`
  taking a `GroupComposition`); the Sprint 1/2 single-filter method is deleted,
  not deprecated alongside it.
