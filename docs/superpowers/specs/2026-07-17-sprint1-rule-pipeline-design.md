# Sprint 1 — Rule Pipeline Foundation: Design

**Project:** ADBLX (SHIELD) · **Sprint:** 1 · **Status:** Design approved, pending implementation
**Prerequisite:** Sprint 0 complete (seven-target XcodeGen scaffold, ADRs, logging policy)
**Owner:** Harsha
**Supersedes/amends:** `ADBLX-Sprint1-Plan.md` (external, approved goal/constraints/parts) — this
document resolves gaps found between that plan and the `ADBLX-Scaffold/Filtering/` code drop
before implementation starts. The original plan's Parts 1–10, hard constraints, and FR/NFR
cross-reference remain in force except where amended below.

---

## 1. Context

Sprint 0 shipped a bundled-JSON-copy path (`ContentBlockerBootstrap`) as a placeholder. The
Sprint 1 plan replaces it with a real, layered rule pipeline (validate → compile → partition →
atomically write → reload), scoped to the Ads extension only, using bundled test fixtures —
no networking until Part 10.

A scaffold (`ADBLX-Scaffold/Filtering/`) already implements each pipeline stage as an isolated
type: `FilterStore`, `FilterValidator`, `RuleCompiler`/`PassthroughRuleCompiler`,
`RulePartitioner`/`PassthroughAdsPartitioner`, `AtomicRuleWriter`, `ReloadCoordinator`, plus
`Models/` and a `Checksum` utility. A gap review against the plan's own Part 1–9 acceptance
criteria found six issues; this document resolves all of them before an execution plan is
written.

---

## 2. Gaps and resolutions

### 2.1 No orchestrator (highest priority)

Nothing in the scaffold composes the six stage types into the actual pipeline. Introduce one
new type:

```
Filtering/
    Pipeline/
        FilterPipeline.swift
```

`FilterPipeline` is the only type that knows the stage sequence:

```
validate → compile → partition → write → persist metadata → reload
```

It owns timing, progress reporting, cancellation, and (future) retry/rollback — none of that
leaks into the individual stage types, which stay single-purpose and independently testable.

Public surface:

```swift
actor FilterPipeline {
    init(
        validator: FilterValidator,
        compiler: RuleCompiler,
        partitioner: RulePartitioner,
        store: FilterStore,
        writer: AtomicRuleWriter,
        reloader: ReloadCoordinator
    )

    func install(filterID: String, source: Data) async throws
    func installBundledSnapshotIfNeeded() async throws
}
```

Dependencies are injected through the initializer (not constructed internally), so:
- Every stage is independently mockable in `FilterPipeline` tests.
- Swapping `PassthroughRuleCompiler` for a future SafariConverterLib-backed compiler (post
  ADR-0001) only changes the composition root — no pipeline code changes.

### 2.2 "Normalize" stage is undefined

The original plan's goal diagram (`Raw → Normalize → Compile → Partition → Atomic Write →
Reload → Safari`) names a Normalize stage that no Part 1–10 owns. Sprint 1 ships a passthrough
compiler with nothing to normalize yet.

**Resolution:** the pipeline sequence for Sprint 1 is:

```
Raw → Validation → Compilation → Partition → Atomic Write → Reload → Safari
```

Normalization becomes a distinct stage once real AdGuard/EasyList parsing lands (post
ADR-0001), likely as a step inside or before `Compilation/`. Not a Sprint 1 deliverable.

### 2.3 `ContentBlockerBootstrap` conflicts with Parts 3 and 5

Sprint 0's `ContentBlockerBootstrap.swift` currently touches the App Group container directly
via `FileManager` (violates Part 3: "no other type touches these paths directly") and calls
`SFContentBlockerManager.reloadContentBlocker` directly (violates Part 5: "grep for direct
calls outside `ReloadCoordinator` returns zero results"). Shipping the new pipeline alongside
the untouched bootstrap leaves both Part acceptance criteria failing.

**Resolution:** reduce `ContentBlockerBootstrap` to a single call at launch:

```swift
enum ContentBlockerBootstrap {
    static func ensureInitialRulesInstalled() async {
        try? await FilterPipeline.shared.installBundledSnapshotIfNeeded()
    }
}
```

All copy/reload/logging logic currently inline in `ContentBlockerBootstrap` moves into
`FilterStore` / `AtomicRuleWriter` / `ReloadCoordinator` via `FilterPipeline`. The file is not
deleted this sprint (launch call site stays), but shrinks to near-empty. `MetricsSubscriber`'s
existing call sites into `ContentBlockerBootstrap` are updated to match the new signature.

### 2.4 Bundled fixtures

**Resolution: no new fixture files.** `ADBLX/Resources/blockerList.json` already exists,
already ships as part of Sprint 0, and is real Safari content-blocker JSON — `FilterPipeline
.installBundledSnapshotIfNeeded()` reads this same file as its Ads source, preserving Sprint 0
launch behavior exactly.

Privacy/Annoyances/Regional extensions each keep their own existing
`Extensions/*/Resources/blockerList.json` bundled copies, loaded the Sprint 0 way, completely
untouched by the new pipeline this sprint (per Part 7's explicit scope line) — no new fixtures
needed for them.

`FilterValidator`'s failure-path tests (empty data, non-UTF8 bytes, malformed JSON) construct
bad input in-memory (`Data([])`, invalid byte sequences, malformed JSON strings) rather than via
committed files — keeps the fixture surface at zero new files this sprint.

### 2.5 `Docs/Architecture/Logging.md` does not exist

Both the external plan and every scaffold file's doc comments cite `Docs/Architecture/
Logging.md` as the authoritative source for the counts-and-durations-only logging constraint.
No such file currently exists in the repo (`docs/Architecture/` has `TargetTopology.md`,
`ManualVerification.md`, `README.md` only) — the constraint has so far only existed informally,
scattered across other docs.

**Resolution:** create `docs/Architecture/Logging.md` before implementation begins:

```markdown
# Logging Policy

## Allowed
counts, durations, sizes, versions, checksums

## Forbidden
URLs, domains, hostnames, rule text, cookies, headers, query strings

No exception for debug builds. If tempted to log "which rules were unsupported," log the
*count*, never the content.
```

This becomes the single doc every future PR touching `Filtering/` or `RuleStatistics` points
to, instead of the constraint being re-stated ad hoc.

### 2.6 No tests exist; `AtomicRuleWriter`'s kill-during-write case needs a seam

None of Part 2's round-trip tests, Part 3's FilterStore-ownership guard, or Part 4's
kill-during-write guarantee are currently testable — XCTest cannot literally kill a process
mid-syscall.

**Resolution:** extract the durability operations behind a protocol seam in
`AtomicRuleWriter`:

```swift
protocol AtomicFilesystem {
    func write(_ data: Data, to url: URL) throws
    func fsync(atPath path: String) throws
    func replace(_ destination: URL, with tempURL: URL) throws
}

struct RealFilesystem: AtomicFilesystem { /* current implementation */ }
```

`AtomicRuleWriter` takes an `AtomicFilesystem` via its initializer (defaulting to
`RealFilesystem()` in production). Tests inject a `FailingFilesystem(afterFSync: true)` (or
`afterWrite:`, `afterReplace:`) that throws at a chosen step, then assert:
- the destination file's prior contents are unchanged (old file still readable),
- no new file exists at the destination path,
- the temp file was cleaned up.

This proves the FR-05 guarantee ("previously-committed compiled JSON intact and loadable, no
corruption, no partial file ever visible") without needing to crash the test process.

### 2.7 Dependency injection boundary (folded into 2.1)

Covered by `FilterPipeline`'s initializer-injected design in §2.1 — called out separately here
only because it's the one addition beyond the original six gaps: every stage type is
constructed outside the pipeline and passed in, so the whole chain — not just
`AtomicRuleWriter` — is independently testable and the passthrough-to-real-compiler swap (post
ADR-0001) touches only the composition root.

---

## 3. Amended Part list

The external Sprint 1 plan's Parts 1–10 stand as written, with one insertion:

```
Part 1    Filtering module skeleton
Part 1.5  FilterPipeline orchestrator          [NEW — see §2.1]
Part 2    Domain Models
Part 3    FilterStore
Part 4    AtomicRuleWriter (+ AtomicFilesystem seam — see §2.6)
Part 5    ReloadCoordinator
Part 6    RuleCompiler protocol
Part 7    RulePartitioner
Part 8    Metadata
Part 9    Validation
Part 10   Networking (final step, unchanged, deferred)
```

Plus two amendments to existing Parts:
- **Goal diagram** (plan §1): corrected to `Raw → Validation → Compilation → Partition →
  Atomic Write → Reload → Safari`, with the Normalize footnote from §2.2.
- **Part 3 acceptance**: `ContentBlockerBootstrap`'s migration (§2.3) is now the concrete
  mechanism by which "no other type touches these paths directly" becomes true, not just an
  aspiration.

All other Parts, the Hard Constraints (§2 of the external plan), the Explicitly Out of Scope
list (§4), the Performance/Battery honest-scope notes (§5), and the FR/NFR cross-reference
(§6) are unchanged.

---

## 4. Target placement (unchanged, restated)

Everything in this document lives in the **main app target only** — `Filtering/` (including the
new `Pipeline/` subfolder), and the `ContentBlockerBootstrap` edit. Nothing moves into
`Packages/ADBLXShared` (gated on ADR-0003) or into any Content Blocker extension target.

Because `ADBLX`'s target definition in `project.yml` uses `type: syncedFolder` at `path:
ADBLX`, dropping `Filtering/` (including `Pipeline/`) under `ADBLX/Filtering/` attaches it to
the target automatically — no `project.yml` changes required. Same for new test files under
`ADBLXTests/`.

---

## 5. Testing summary

| Component | Test | Notes |
|---|---|---|
| Models (Part 2) | Round-trip encode/decode per model | Per plan acceptance |
| `FilterStore` (Part 3) | Only type touching App Group paths | Enforced by not exposing container URL outside the type (existing scaffold already does this) |
| `AtomicRuleWriter` (Part 4) | Fault-injected write/fsync/replace via `AtomicFilesystem` seam | See §2.6 — replaces literal kill-during-write |
| `ReloadCoordinator` (Part 5) | Grep for direct `SFContentBlockerManager` calls outside this file returns zero | Requires §2.3 migration to actually pass |
| `FilterValidator` (Part 9) | Empty / oversized / non-UTF8 / invalid-JSON in-memory cases | No new fixture files — see §2.4 |
| `FilterPipeline` (Part 1.5) | Full pipeline run against `ADBLX/Resources/blockerList.json`, with each injected stage mockable | New — proves end-to-end wiring, not just individual stages |

---

## 6. Out of scope (unchanged from external plan)

BGTaskScheduler / daily background updates, Packet Tunnel (DNS), Safari Web Extension
(YouTube), Regional filter UI, StoreKit, premium gating, and all of Part 10 (networking) until
Parts 1–9 pass their acceptance criteria against bundled fixtures.
