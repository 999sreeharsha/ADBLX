# Gotchas

Known pitfalls in this codebase, captured from post-implementation review (ABORT
review / harden-plan). Check here before planning new work that touches the same
areas.

## Set-equality assertions can't catch transposed key→value mappings

When a test asserts on the *output* of a mapping (e.g. `FilterGroup` →
extension identifier via `GroupExtensionIdentifiers`, or any other N-key,
N-value correspondence) using `Set(...) == [...]` or unordered membership
checks, it can prove "all N values appeared somewhere" but not "value X paired
with key X" — a transposition (two values swapped between two keys) passes
undetected, because both sides of a swap still appear in the set. Assert
positional/pairwise correspondence instead (ordered array equality against
literals *not* derived from the same constant used to build the system under
test, or an explicit per-key lookup), whenever a test's whole purpose is to
verify a mapping's correctness rather than its coverage.

Found in: `docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md`, 2026-07-19

## Batch/transactional test coverage needs a partial-failure-mid-batch case, not just single-item failure

`FilterStore.snapshotForRollback()`/`restore()` and `UpdateCoordinator.run()`
wrap an entire multi-item batch (multiple `FilterGroup` installs) in one
rollback transaction. A test that only fails the batch's *sole* item (as
Sprint 2's rollback test did, when there was only ever one group to install)
does not exercise the case where item 2 of N succeeds and writes real state
before item 3 throws — which is exactly the scenario the rollback exists to
handle. Any future test suite for a batch/transactional operation in this
codebase should include a case that fails partway through a batch of 2+ items,
not just a batch of 1.

Found in: `docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md`, 2026-07-19

## InstalledFilter.ruleCount is group-level, not per-source, once composition lands

Sprint 3A's `FilterPipeline.install(_ composition:reloadStrategy:)` writes the
same `compiled.ruleCount` (the whole group's aggregate compiled rule count)
into every source's `InstalledFilter` entry, because `ComposedRules`/
`CompositionService` never tracked per-source counts — only a group-level
total. For a multi-source group, every source's `InstalledFilter.ruleCount`
reports the same number, not that source's own contribution. Documented on
the field itself (`InstalledFilter.swift`); if a future feature needs true
per-source rule counts (e.g. a per-filter breakdown UI), `ComposedRules` will
need to carry a `[String: Int]` per-source count map threaded through
`CompositionService.compose`.

Found in: `docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md`, Task 7 review, 2026-07-20

## FilterPipeline's dependency-construction boilerplate is repeated verbatim across many test files

`FilterPipeline(validator:compiler:compositionService:partitioner:store:writer:reloader:)`
and `GroupExtensionIdentifiers(ads:privacy:annoyances:regional:)` literals are
constructed by hand in `FilterPipelineTests.swift`, `UpdateCoordinatorTests.swift`,
and `AppCompositionRoot.swift` — any future change to `FilterPipeline.init`'s
signature or to the four canonical extension bundle IDs requires touching every
call site by hand, with no compiler-enforced way to catch a stale or mistyped
one. When adding a new dependency to `FilterPipeline` or changing the extension
identifier mapping, grep for all constructors before assuming a change is
complete: `grep -rn "FilterPipeline(" ADBLX/ ADBLXTests/` and
`grep -rn "GroupExtensionIdentifiers(" ADBLX/ ADBLXTests/`.

Found in: `docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md`, 2026-07-19

## A task boundary that ends with an expected `BUILD FAILED` is two tasks wearing one commit split

Plan tasks are supposed to each end with an independently testable/working
deliverable (writing-plans skill's Task Right-Sizing rule). Sprint 5A's Task
4→6 split committed a `HomeStatus` model change whose consuming view
(`HomeView.swift`) wasn't fixed until the next task, with an explicit "expected:
BUILD FAILED, this is expected" step in between. Sprint 5B's plan repeated the
same pattern for Task 7→8 (`AppearancePreferenceStore` wired into
`ADBLXApp.swift`'s `RootTabView(...)` call site before `RootTabView` itself
accepted the new parameter) and cited the Sprint 5A precedent as justification.
An ABORT review (2026-07-26) flagged this as a compounding anti-pattern: citing
a prior sprint's broken-build split as precedent, rather than treating it as a
one-off exception, risks normalizing "ship a non-compiling commit, fix it next
task" as acceptable convention. When a model/type change and its sole consumer
are so interdependent that splitting them leaves an intermediate commit
non-compiling, that's a signal the two tasks are one task with an oversized
diff — restructure so either (a) the type change and its consumer land in one
task/commit, or (b) the earlier task adds only the new, additive code with no
call site changes to existing signatures, deferring all wiring of
already-shipped call sites to the task that actually changes those signatures.

Found in: ABORT review of `docs/superpowers/plans/2026-07-26-sprint5b-feature-live-data.md`, 2026-07-26

## Symmetric-looking aggregation logic needs the same guard on every field, not just the one bug already known

Sprint 5B's planned `RealProtectionService.fetchStatus()` explicitly guards
against `ruleCount` double-counting when a group has 2+ `InstalledFilter`
entries (taking `groupFilters.first?.ruleCount` per the group-level-count
gotcha above), but the same method's `filterLists` construction maps `filters`
directly to `FilterListEntry` values with no uniqueness/dedup handling at all
— an asymmetry an ABORT review (2026-07-26) flagged as the kind of thing that
looks intentional ("we already handled the known gotcha here") but actually
just means the second field's failure mode hasn't been hit yet. Currently
unreachable (no real CDN manifest exists yet, so filter IDs can't collide
across groups in practice — Sprint 5A's `AppManifestEndpointProvider` is still
a placeholder), but once real manifest data lands this becomes a live bug with
no test coverage, because the existing test suite's fixtures only ever
construct filters with already-unique IDs. When one field in an aggregation
method gets an explicit correctness guard, audit every sibling field derived
from the same source collection for the same class of bug before assuming the
method is safe.

Found in: ABORT review of `docs/superpowers/plans/2026-07-26-sprint5b-feature-live-data.md`, 2026-07-26

## Settings screen (Sprint 5B): several rows look fully functional but are deliberately half-wired

Sprint 5B's brainstorming pass explicitly deferred multiple pieces of Settings
functionality rather than building them — each is a considered scope cut, not
an oversight, but none of it is visually distinguishable from a fully-working
row once rendered, so a future contributor extending this screen needs to know
which rows are load-bearing and which aren't before building on top of them:

- **Allowlist is storage-only, with no enforcement.** `AllowlistStore` and
  `RealSettingsService` persist add/remove operations across launches
  (`allowlist.json`, atomic writes, same pattern as
  `installed_filters.json`/`filter_preferences.json`), but nothing in
  `FilterPipeline`/`CompositionService`/`RuleCompiler` reads that file or
  exempts any domain from blocking. A user can add a domain to their allowlist
  today and it will keep being blocked — the row is real UI, real persistence,
  and zero actual effect. Real enforcement needs new work in the compilation
  pipeline, not just the storage layer already built.
- **Notifications and Safari Help are `ComingSoonState` navigation targets,
  not real screens.** Both rows navigate successfully (no crash, no dead
  link), but land on the same shared placeholder component used elsewhere in
  the app for not-yet-built features. Notifications specifically needs real
  `UNUserNotificationCenter` permission-status wiring before it can be
  anything but a placeholder — there is no notification permission request or
  status display anywhere in this codebase yet.
- **Language is read-only and does not localize the app.** The row displays
  `Locale.current`'s system language name accurately, but there is no in-app
  language override — picking a different language anywhere else on the
  device changes what this row shows, but nothing in Settings can change it.
  Building an actual in-app language picker is a larger localization-
  infrastructure task (separate from the `Localizable.xcstrings` string
  migration work Sprint 4C already did), explicitly out of scope here.
- **iCloud Sync stays hardcoded `false`/non-functional**, unchanged from the
  pre-Sprint-5B mock — there is no iCloud sync backend anywhere in this
  codebase. This one predates Sprint 5B entirely and was correctly left alone
  (not a new gap), but is easy to lump in with the other half-wired rows above
  if auditing this screen later — worth distinguishing "never was in scope"
  from "deliberately deferred this sprint."

None of this is a defect in what shipped — every one of these was an explicit
design-doc decision (`docs/superpowers/specs/2026-07-26-sprint5b-feature-live-data-design.md`,
"Out of scope" section and Commit 3). The risk is purely that Settings now
*looks* like a fully real screen (every row responds, nothing is visibly
mocked, per Sprint 5's own "no fabricated values" standard for the *data* that
is shown), while several rows' *actions* still do nothing beyond
navigation/storage. Before building any feature that assumes the allowlist
actually blocks/unblocks content, or that Notifications/Safari Help/Language
are functional, re-read this entry — the UI presence of a row is not evidence
the underlying capability exists.

Found in: `docs/superpowers/specs/2026-07-26-sprint5b-feature-live-data-design.md` (Out of scope, Commit 3), Sprint 5B brainstorming, 2026-07-26
