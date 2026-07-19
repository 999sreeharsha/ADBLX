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
