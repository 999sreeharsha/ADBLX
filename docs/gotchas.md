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

- **Allowlist (superseded, 2026-10-30):** this entry originally said the
  allowlist was storage-only. That is no longer true: `FilterPipeline.syncAllowlist`
  compiles the domains with `SafariAllowlistCompiler` (`FilterPipeline.swift:208`)
  and DNS enforces them too (ADR-0009). See SEC-01 in
  `docs/Security/Findings.md` for the remaining gap.
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

## `JSONEncoder` with `.prettyPrinted` does not preserve struct declaration order — a fixed key order needs a manual writer or `.sortedKeys`

On this project's Swift 6.3 toolchain (`swiftlang-6.3.3.1.3`, macOS 26,
arm64), encoding a `Codable` struct with `JSONEncoder.outputFormatting =
[.prettyPrinted]` does **not** reliably emit keys in declaration order —
`Codable`'s default key ordering follows `Dictionary`'s per-process hash
seed, which is randomized per process launch. Encoding the same value five
times via a standalone script produced a different key order in four of the
five runs. `.sortedKeys` fixes the determinism (alphabetical, stable) but
does not produce declaration order — if a spec mandates a specific
non-alphabetical key order (as `backend/docs/ManifestSpecification.md` does
for `manifest.json`), `.sortedKeys` alone still violates the spec even
though it makes the *test* deterministic.

This bit twice in the same sprint: Task 10 (Publisher's integration tests)
used `JSONEncoder` + `.sortedKeys` as a stopgap in its golden-manifest test
before the real production serializer (`ManifestJSONWriter`, added in Task
11) existed — an accepted, documented workaround at the time. But the final
whole-branch review caught that the golden fixture and test were never
updated once `ManifestJSONWriter` landed, so the repo briefly had a
committed golden file asserting the *wrong* (alphabetical) key order for the
tool whose entire job was to guarantee the *right* one. A task-scoped
reviewer looking at either Task 10 or Task 11's diff alone had no way to
catch this — it only became visible once the whole branch was reviewed
together and someone checked whether the "temporary" `.sortedKeys` decision
had actually been superseded.

If a future task's plan explicitly documents "use X as a stopgap until task
N lands the real thing," the plan (or the SDD ledger) should carry an
explicit item for task N's implementer/reviewer to revisit and close out
the stopgap — otherwise it silently survives past the point it stopped
being justified.

Found in: `docs/superpowers/plans/2026-07-27-sprint7-publisher-implementation.md`, Task 10/11 final whole-branch review, 2026-07-27

## StoreKit Local Configuration does not activate under headless `xcodebuild test` — one test permanently skipped, not a code bug

`StoreKitSubscriptionServiceTests.fetchStatusReturnsTwoPlans` (which exercises
`StoreKitSubscriptionService.fetchStatus()` against the local `Products.storekit`
configuration bundled in Task 12's scheme) fails only when run via CLI
`xcodebuild test`, on this project's Xcode 26.6 toolchain (build 17F113). It
does not indicate a bug in `StoreKitSubscriptionService`:

- `StoreKitSubscriptionServiceTests.isPremiumEntitledFalseWithNoTransactions`
  (same suite, same service, no StoreKit product data dependency) passes
  reliably under both `xcodebuild build` and `xcodebuild test`.
- `xcodebuild build` succeeds cleanly — this is a *test-execution-environment*
  gap, not a compile or wiring problem.
- Manually running the suite via Xcode's own GUI test runner (Cmd+U) exercises
  the same `.storekit` configuration correctly and is expected to pass; this
  has been verified in this sprint's development process, just not captured
  automatically by any CI/headless invocation.

Workarounds tried and ruled out before accepting this as a tooling limitation:
fresh `DerivedData`, pinning an explicit simulator UDID (rather than a named
destination), splitting `build-for-testing` from `test-without-building`,
attempting a programmatic `SKTestSession` workaround to force-activate the
local StoreKit configuration outside the GUI runner. None reactivated local
product data under the CLI path. This is corroborated externally by a live,
open Flutter GitHub issue describing the same StoreKit Local Configuration
daemon activation gap under headless `xcodebuild test` on the same Xcode 26.x
generation — i.e., not unique to this codebase's setup.

No reliable runtime-detectable signal was found to distinguish "running under
Xcode's own GUI test runner" from "running under CLI `xcodebuild test`" — an
ad hoc `ProcessInfo.processInfo.environment` dump added to the test and run
under `xcodebuild test` showed only environment variables xcodebuild itself
documents/sets (`XCTestBundlePath`, `XCTestSessionIdentifier`,
`OS_ACTIVITY_DT_MODE`, `PERFC_*`, etc.) with no counterpart GUI-run capture
available in this headless environment to diff against with confidence.
Rather than invent an unverified detection heuristic, the test is
unconditionally skipped via Swift Testing's `.disabled("...")` trait, with an
explanatory message pointing at this entry, and remains present/compiled/
runnable — not deleted or commented out — so it goes green automatically the
moment the trait is removed on a future Xcode version where this gap is
fixed.

Likely root cause: a StoreKit Local Configuration daemon (`storekitd`-adjacent
test support process) that Xcode's GUI test runner starts/attaches as part of
its own test host lifecycle, but which `xcodebuild test`'s CLI-driven test
host launch does not equivalently trigger.

Re-evaluate this the next time Xcode is upgraded on this machine: re-run
`xcodebuild test` with the `.disabled` trait temporarily removed to check
whether the underlying daemon-activation gap has been fixed upstream before
assuming it's still broken.

Found in: `docs/superpowers/plans/2026-07-27-sprint-8.0-foundation-completion.md`, Task 12, 2026-07-28

## Entitlement gating: `UpdatePlanner` only gates downloads — revocation lives in `PremiumEntitlementReconciler`

**Status (2026-10-29): closed for content blockers.** `UpdatePlanner.plan`
checks `entry.premium && !isPremiumEntitled` *before* the installed-filter
lookup, so for a not-entitled user an already-installed premium entry yields
`.skipPremium` (never `.keep`/`.install`), which `UpdateCoordinator` ignores.
That prevents re-downloads but does **not** remove what is already on disk.
Removal is the job of `PremiumEntitlementReconciler`, which is level-triggered
(compares installed filters against entitlement on every run — launch,
foreground, entitlement change, before `UpdateCoordinator.run()` — with no
"last reconciled" state) and covers trial expiry, subscription lapse and
refund/revocation identically, because all of them surface as the
`EntitlementService` reporting no premium access.

Things to remember when touching this:
- `InstalledFilter.premium` is `Bool?`; `nil` means a legacy record and is
  resolved from the cached manifest, then `BundledPremiumCatalog`, then
  persisted. Do not default it to `false`.
- A `304` manifest returns from `UpdateCoordinator.run()` before planning, so
  enforcement must never depend on `run()`. Likewise re-entitlement clears the
  cached ETag, otherwise a premium list the user lacks is never fetched.
- Mutating transactions share one `Previous/` rollback directory; anything that
  snapshots must run inside `FilterTransactionGate.shared`.
- Content-blocker JSON is static, so Annoyances/Regional keep blocking until
  the next launch/foreground reconcile. The web extension and tunnel enforce
  `validUntil` themselves (subscription expiry + 7 days; trial exact) — but
  the tunnel's check does not look at `state`, so a `.free` record is allowed
  (SEC-13 in `docs/Security/Findings.md`).
- Open product input: Apple's Billing Grace Period (enable in App Store
  Connect if lapse leniency is wanted) and Family Sharing are product
  decisions, not code.

Found in: final whole-branch review of `docs/superpowers/plans/2026-07-27-sprint-8.0-foundation-completion.md`, 2026-07-28. Promoted to a release blocker in Sprint 8.05; closed by `docs/superpowers/plans/2026-10-29-plan-state-and-downgrade.md`, 2026-10-29.

## Trial is Keychain-only with no IAP record — App Store Guideline 3.1.1 review risk (accepted for now)

The 15-day trial (`TrialManager` / `TrialKeychainStore`) has no StoreKit record
behind it: `Configuration.storekit` has `introductoryOffer: null` on every
plan, and `StoreKitSubscriptionService.refreshEntitlements()` merges the
Keychain trial with `Transaction.currentEntitlements` by precedence. A
Keychain-only trial may draw a Guideline 3.1.1 objection at review. This is an
explicit, accepted decision (`docs/Architecture/PD-01-monetization-and-trial.md`
§2 — no StoreKit-managed trial), not an oversight. It is also only partly
clock-tamper resistant (`lastObservedDate` guards against moving the clock
backwards between observations, not against a reinstall-then-wipe).

Candidate fix if review pushes back: a zero-price non-consumable "15-Day
Premium Trial". If migrated, existing `TrialRecord`s must be grandfathered
(honour the remaining days) rather than reset. Keep trial access behind the
`TrialSource` protocol (Plan State work) so that swap touches one type.

Found in: Plan State + Downgrade planning, 2026-10-29

## New premium lists must be added to `BundledPremiumCatalog`

`BundledPremiumCatalog` (`ADBLX/Filtering/Models/BundledPremiumCatalog.swift`) is
the app's offline knowledge of which filter IDs are Premium-gated and bundled.
Two things depend on it: classifying legacy `InstalledFilter` records that have
no `premium` flag when no cached manifest exists, and deciding what an entitled
user should have installed from the bundle. Adding a premium list (a new bundled
`.txt`, or a new `premium: true` manifest entry that should work offline) means
updating the catalog **and** `installBundledPremiumSnapshot`. A test
(`BundledPremiumCatalogTests`) asserts the catalog IDs exactly equal the
premium lists the bundled snapshot installs, so a forgotten update fails CI
rather than silently leaving a lapsed user with the rules installed.

Found in: Plan State + Downgrade Phase 2 review, 2026-10-29

## A test type conforming to a `nonisolated` protocol must itself be `nonisolated` — or the compiler blames a different file

Both targets build with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`. A test double
declared as plain `final class Foo: SomeNonisolatedProtocol` is therefore
MainActor-isolated, and its conformance to a `nonisolated protocol` is invalid. On
this toolchain the compiler does **not** report that against the offending file:
it reports `'nonisolated' modifier cannot be applied to this declaration` on
`actor MockContentBlockerStateProvider` in
`ADBLXTests/Filtering/Deployment/ContentBlockerStateProvidingTests.swift`, a file
nobody touched. Incremental builds sometimes hide it, so it looks flaky. Fix: mark
the new test double `nonisolated final class` (the same way production conformers
such as `SystemContentBlockerStateProvider` are declared). When that error appears,
look at test types added since the last green build, not at the file named in it.

The same error comes from a new main-actor-isolated type (the default for a plain
`enum`/`struct` in the app target) used in a `nonisolated` protocol's requirements: adding
`AllowlistEditOutcome` as `SettingsService`'s return type produced it, on a clean build too,
until the enum was declared `nonisolated`. Look at changed protocol signatures as well as new
test doubles. A nested `private struct` inside a `nonisolated struct` didn't trigger it, but a
reference to an actor's `nonisolated static` method used as a default argument
(`swapPaths: ... = FilterStore.swapPathsAtomically`) did; wrapping it in a closure
(`{ try FilterStore.swapPathsAtomically($0, $1) }`) fixed it.

Found in: entitlement purchase-bug fix (`FakeStoreEntitlementSource`), bisected 2026-10-30

## DNS Protection breaks app connectivity and payments (OPEN — blocks shipping DNS)

- Observed 2026-10-30 on iPhone 14: with DNS Protection on, many apps can't reach
  the internet and payment/UPI flows fail.
- Not yet diagnosed. Suspects, in order:
  1. The tunnel's routes capture more than DNS traffic. Check `includedRoutes`: it
     must route only the tunnel's DNS address, never the default route.
  2. IPv6 DNS/AAAA handling on Jio/Airtel mobile data.
  3. No TCP fallback for truncated responses, and upstream timeouts that hang
     instead of failing fast.
  4. Blocklists blocking payment-gateway or bank anti-fraud domains.
  5. Some banking/UPI apps refuse transactions while any VPN is active. Not fixable
     in code; needs "Pause" UX.
- Decisive test: run the tunnel in pass-through mode (empty blocklist). Still
  broken → tunnel bug; fixed → list over-blocking.
- Open owner decision: whether to amend `Logging.md` for an on-device-only,
  user-visible, auto-expiring "Recently blocked" list.
- Rule until closed: DNS Protection must not be enabled in any release or
  TestFlight build.
  `DNS_PROTECTION_ENABLED` (`Config/Debug.xcconfig` only) enforces this: Release
  hides every DNS surface and doesn't embed the tunnel. See SEC-04.
- Ruled out (2026-10-31): the content-blocker "unsupported domain dropped →
  rule becomes unrestricted" bug (next entry). The DNS blocklist parser
  (`DNSDomainNormalizer`) shares no code with `SafariRuleGenerator`. It rejects
  any line with `$` modifiers, `*`, `/`, `?`, `:` or `^` in the host, so an
  unsupported domain produces no DNS rule rather than a wider one.

Found in: device testing on iPhone 14, 2026-10-30

## Compiler: dropping an unsupported domain must never widen a rule

Safari's `if-domain`/`unless-domain` cannot express entity domains (`site.*`)
or paths. `SafariRuleGenerator` used to strip them and, when none were left,
emit the rule with no domain restriction. `myloview.*#@#.cookiesInfo` became an
unrestricted `ignore-previous-rules` that cancelled every earlier Annoyances
rule on every page (0 effective rules on ordinary sites while reporting 48,451
rules and a clean reload). Two `@@||jokerly.com/…$document` lines did the same
to Ads document loads, and `site.*##` hiding rules became global hides.

The fix:
- A rule whose domains are all unsupported is dropped.
- A rule left with only exclusions is dropped and counted separately.
- A generic `#@#` exception is dropped.
- `NativeABPRuleCompiler` fails the group's compile if any unrestricted
  exception remains, so the last-good rules stay installed.
- `BundledListScopingRegressionTests` checks the shipped lists.

A rule count and a successful reload do not show that rules take effect.
Check the effective rules for a real page.

Not released: the app has never been uploaded to the App Store or TestFlight,
so no hotfix is needed.

Pre-fix blocking measurements are invalid. The Ads page-wide exceptions
cancelled earlier Ads rules on every page load, and Annoyances applied nothing
on ordinary pages, so any ad-blocking or AdBlock-Tester / G1 measurement taken
before `8b07893` is invalid. Re-measure G1 on a device after this fix.

Pre-launch item (before App Store submission, not now): store a compiler
version alongside the installed compiled rules, and on launch recompile every
group from its stored lists when it differs from the app's compiler version.
Today an existing install keeps rules from the old compiler until a list
update or an allowlist edit happens to recompile that group, so a compiler fix
does not reliably reach it. The
DEBUG Developer screen's "Recompile all now" is the manual stand-in for device
testing.

Found in: cookiebot.com banner still visible with Annoyances on, iPhone 14, 2026-10-31

## Annoyances has two sources: Fanboy plus SHIELD fixes (not published yet)

`shield-fixes` (`backend/public/filters/annoyances/shield-fixes.txt`, premium) holds
rules the upstream lists lack. It is composed after `fanboy-annoyances`, so no
upstream exception can cancel it. First entry: `###CybotCookiebotDialog`, found on
cookiebot.com (classic dialog in the page DOM, no shadow root).

- **Update path.** A group compiles to one rule set, so `UpdateCoordinator` now
  recomposes it from all of its entitled sources, using the stored payload for
  unchanged ones. Before this, an update that changed one source of a group
  dropped the others' rules. It was latent while every group had one source.
- **Bundled too.** The entry is in `BundledPremiumCatalog` and
  `installBundledPremiumSnapshot`; the reconciler installs it for an entitled user
  who has Fanboy but not the fixes, at the next launch or foreground.
- **Three copies to keep equal:** the backend payload, the bundled copy in
  `ADBLX/Resources/Filters/`, and the manifest checksum
  (`ShieldFixesListTests` checks the first two). After editing the list, bump
  `backend/metadata/shield-fixes.json` and run the Publisher.
- **Not deployed.** The registry, manifest and docs are regenerated locally;
  nothing is on gh-pages until someone runs `backend/tools/publish-pages.sh`.
- **`sourceURL` layout (decided 2026-11-06): `<base>/filters/<group>/<id>.txt`,
  never `/backend/public/`.** `publish-pages.sh` copies `backend/public/` to the
  Pages root, so the repo path is not part of the URL. The Publisher
  (`ManifestBuilder`), `ManifestGeneration.md` and `ManifestSpecification.md` now
  agree; `ManifestTests` pins the builder and `CommittedManifestTests` pins the
  committed `manifest.json` (a manifest generated before `aa64fef` carried the old
  form).
- **Fanboy already includes the `easylist_cookie` sections** (general, specific
  and international hide and block, third-party, and the allowlists), so a
  separate EasyList Cookie List would mostly duplicate it.
- **Known coverage limit, post-launch:** banners served inside an iframe by a
  consent platform (Sourcepoint on theguardian.com) are not covered by these
  rules.

Found in: cookiebot.com banner investigation, iPhone 14, 2026-11-03

## A corrupt `installed_filters.json` recovers from the bundle, and a failed read must not

`writeMetadata` is already atomic (`.atomic`, guarded by
`concurrentWriteNeverProducesTornRead`). `FilterStore.restore` used to delete each
directory and copy files back; it now swaps each one in with a rename, so a directory is
never half-restored. A crash between two swaps can still leave `Compiled/` and
`Metadata/` from different points.

- `PremiumEntitlementReconciler` treats the file as lost when it reads but won't decode,
  or when it's missing while compiled rules exist (the pipeline always writes it after
  compiling). It reinstalls the free bundled lists, clears the ETag and the update
  throttle, then reconciles as usual. Drift repair never runs from a lost file.
- A failed read is left alone. It can be temporary (before first unlock) and the file
  may be fine.
- Recovery is all-or-nothing. A partial install would make the other groups look
  sourceless, and drift repair would empty them.
- It runs once per launch, because a full disk would otherwise repeat a full compile.
- Lists from an update (Regional, say) are gone until the next update run. Clearing the
  throttle lets that run at the next opportunity: the same launch, since reconcile runs
  before the throttle check.

Found in: review of the empty-group repair, 2026-11-05

## WKErrorDomain code 6 can surface in two places, and they behave differently

Code 6 is `WKErrorContentRuleListStoreCompileFailed` (`WKError.h`). Bad rules cause it;
low disk is the suspected cause of the flaky `PayloadPersistenceTests` run.

- **The WebKit gate in `FilterPipeline.installGroup`** runs before anything is written.
  A rejection rolls back, the rule files stay byte-identical and the sheet reports
  failure.
- **`SFContentBlockerManager` reload** runs after commit, so the rule file has already
  changed and can't be "unchanged". Don't roll back on it: a turned-off blocker can fail
  here too. `UpdateProgressModel` reports it for any blocker not reported as off, and
  `UpdateCoordinator` retries it for enabled ones through `pending_reloads.json`, even
  on a 304.

Whether Safari keeps the previous rules after a failed reload is assumed, not verified
on a device. Reloads outside the update path (allowlist edits, reconcile) only reach
the DEBUG diagnostics log. A failed compile during an allowlist edit reverts the edit
with no message.

Found in: `PayloadPersistenceTests` investigation, 2026-11-05

## Each session tests on its own simulator

Two `xcodebuild test` runs on one simulator kill each other's test runner. The run
logs "Restarting after unexpected exit" or "exited before establishing connection",
and a test can drop out of the results without failing, so a short result list can
look like a pass.

- At the start, create a simulator for the session and note its UDID:
  `xcrun simctl create "adblx-<session>" <device type> <runtime>`. Copy the device
  type and runtime from `xcrun simctl list devices -j` for an existing iPhone.
- Pass it to every test command: `-destination "platform=iOS Simulator,id=<UDID>"`.
  `Scripts/find-simulator-udid.sh <UDID>` checks it still exists.
- Delete it when the session ends: `xcrun simctl delete <UDID>`.
- Before trusting a run, compare its test count with the last full run. A smaller
  count is a lost test, not a pass.

Found in: corrupt-metadata recovery tests, 2026-11-05

## Security findings live in `docs/Security/Findings.md`

The open findings from the 2026-10-30 to 2026-11-04 security audit are tracked
there with stable IDs (SEC-01 onward), a status and corrected fixes. Check it
before touching entitlement, the filter pipeline, the manifest, the DNS tunnel
or the web extension. Two fixes first proposed in the audit were wrong; use the
corrected versions there.

Found in: security audit and review, 2026-11-05
