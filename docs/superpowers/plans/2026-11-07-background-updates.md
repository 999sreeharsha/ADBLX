# Background filter updates (BGAppRefreshTask + BGProcessingTask)

Branch: `feat/background-updates`, off `feat/plan-state-downgrade`. Third draft: approved with
four additions (the commit point, staged files tied to their manifest, whole groups only, staged
premium files cleared on lapse) plus the Info.plist entries, all folded in below. Closes the
gotcha "Pre-launch: the PRD promises free weekly auto-updates, but nothing schedules them".

## What exists today

- The only automatic update is at launch: `AutomaticUpdate.runIfDue` from `ADBLXApp`'s
  detached launch task, throttled to 6 hours by `UpdateThrottle` (`update_throttle.json`,
  one `lastSuccessAt`). A rejected manifest advances the throttle; any other failure doesn't.
- `UpdateCoordinator.run()` does everything in one transaction under
  `FilterTransactionGate.shared`: fetch and verify the manifest, plan, download and verify every
  changed list, then snapshot, install each group, commit or restore. It joins an in-flight run
  on the same instance. It never checks for cancellation.
- **A process killed mid-transaction is not recovered.** It leaves `Previous/` on disk, nothing
  at launch looks at it, and the next transaction's snapshot deletes it. Whatever was half
  written stays: some groups new, some old, `Metadata/` from either side. Reconcile's drift
  repair recompiles a group whose sidecar no longer matches its sources, but nothing puts the
  pre-transaction state back. This is a crash-recovery gap today, and background work makes it
  likelier (iOS kills an app shortly after a background task expires).
- PRD §5.1 row: "Automatic filter updates | ✅ (weekly) | ✅ (frequent; push-triggered planned,
  see Open Question 4)". The paywall lists **Background Updates** as Premium ("Blocklists stay
  fresh automatically…", `premium.feature.backgroundUpdates.*`).

## Decided: free and Premium both get background updates, with no promised schedule

iOS decides when background refresh runs. `earliestBeginDate` is only a floor, and on a phone
where the app is rarely opened iOS may hardly run it at all. Copy promises no interval:

- **Free: "Automatic updates."** The app asks for a background check no sooner than 7 days after
  the last successful one.
- **Premium: "More frequent updates."** No sooner than 24 hours after the last success.
- How often lists are published (manual signing) caps both anyway.

Copy changes (task 7):
- PRD §5.1 row: `| Automatic filter updates | ✅ (automatic) | ✅ (more frequent; push-triggered
  planned, see Open Question 4) |`.
- Paywall: `premium.feature.backgroundUpdates.title` "Background Updates" → "More Frequent
  Updates"; description → "Blocklists are checked for updates more often, in the background."
  The enum case and keys keep their names.
- The Home plan card's "Filter updates when you open the app" becomes "Automatic filter updates"
  for both plans.

## Design

### Split the work: download in the refresh, compile in a processing task

A `BGAppRefreshTask` gets about 30 seconds, and if its expiration handler can't stop the work,
iOS kills the app. Compiling a 150K-rule group is CPU work that nothing can interrupt today. So
the refresh task never compiles:

- **Refresh task** (`com.ADBLX.ADBLX.filter-refresh`): fetch the manifest, verify its
  signature, plan against the installed lists and the current entitlement, download and verify
  the changed lists. Network-bound and cheap. Target: under about 20 seconds on the iPhone 14
  for a full set of changed lists (about 5.3 MB), checked in the spike. Writes only to
  `Staged/`, never to `Compiled/`, `Metadata/` or `Filters/`, so being killed costs nothing but
  the staged files.
- **Processing task** (`com.ADBLX.ADBLX.filter-install`, a `BGProcessingTaskRequest` with
  `requiresExternalPower = true`, `requiresNetworkConnectivity = false`), submitted when
  something is staged. It installs the staged update. iOS gives these minutes, typically while
  the phone is charging and idle, so compiling costs no battery.
- **Launch** installs anything still staged before its own throttled update, so a phone that's
  never charged and idle still gets the update at its next open.

If the spike shows even a full download doesn't fit in about 20 seconds, the refresh stages
lists one at a time across runs (each list verified on its own) rather than moving to background
`URLSession` downloads. That's still one task, just resumed; see "Whole groups only" below.

### Staging (`UpdateCoordinator` split in two)

- `prepare() -> PreparedUpdate?`: the current steps up to and including download and verify,
  without the snapshot. Returns `nil` on a `304` or when nothing changed. It doesn't save the
  manifest or ETag to the cache: a launch must not get a `304` for an update that hasn't been
  installed.
- `apply(_:)`: under the gate, in a rollback transaction (rules below). Saves the manifest and
  ETag to the cache inside the transaction, so they commit or roll back with the rules.
- `run()` stays `prepare()` then `apply()` in one gate hold, so the foreground update sheet and
  tests behave as today.

### Staged files are tied to the manifest they were verified against

`Staged/` holds at most one set of lists, all from one manifest:

- `Staged/stage.json` records the manifest's raw bytes and signature file (not just the decoded
  value), its ETag, its `manifestVersion`, and one entry per staged file: filter ID, group,
  version, SHA-256, size and whether it's premium. Payloads sit beside it as `<filterID>.txt`.
  It's written last, atomically, after every payload it names, so a kill mid-download leaves
  payloads `stage.json` doesn't name. They're deleted the next time `Staged/` is opened.
- **At install time** `apply` verifies the stored manifest again with the real `ManifestVerifier`
  (signature, format, minimum and rollback against the cached manifest as it is now). It
  discards the whole stage if that fails, including when the cache has meanwhile moved to the
  same or a newer manifest (an older or equal `manifestVersion` is rejected as a rollback or
  `.unchanged`). Then it checks each payload's size and SHA-256 against **that manifest's**
  entry, not only against `stage.json`'s copy. Any mismatch or missing file discards the stage,
  and nothing is installed from it.
- **A newer manifest supersedes the stage.** When `prepare` verifies a manifest newer than the
  staged one, staged files whose SHA-256 equals the new manifest's entry for the same filter ID
  are kept (same bytes, re-recorded under the new manifest); every other staged file is deleted.
  Then `stage.json` is rewritten for the new manifest. So no file from an older manifest is ever
  installed, and `Staged/` never holds two sets.
- **Deleted once used.** Inside the `apply` transaction, `Staged/` is emptied after the installs
  and before the commit point. `Staged/` is outside the snapshot, so a rollback can't bring it
  back. That costs a re-download after a failed install, never a duplicate set. A stage that is
  discarded is deleted at once.

### Whole groups only

A group compiles to one rule set from all of its sources, so installing it from some new lists
and some old ones would produce a state no manifest describes. `apply` installs a group only
when every list the plan wants to change in that group is staged and checks out against the
manifest. A group still waiting for a list is left as it is and stays staged. Its kept sources
come from the installed payloads, as today, only for lists whose installed version is the one
that manifest names. Removals apply per group under the same rule. With one list per run, the
refresh keeps downloading into the same stage until the plan is complete, then submits the
processing task. Partial stages never trigger it, but a launch installs every group that's
complete and keeps the rest staged. The manifest and ETag are saved to the cache only when
`apply` has installed every group the plan changes. Otherwise the next check fetches the
manifest again and finishes the stage.

### A lapse clears staged premium files

`apply` re-plans against the installed lists and the entitlement as they are now, so a lapsed
user never gets a premium list installed from the stage. The files mustn't wait on disk either:

- `PremiumEntitlementReconciler`, whenever it finds the user not entitled (the same
  level-triggered check that removes installed premium rules), deletes every staged entry marked
  premium and its payload, and rewrites `stage.json` without them.
- `prepare` never stages a premium list for a not-entitled user (the planner already returns
  `.skipPremium`).
- If removing the premium entries leaves a group incomplete under "Whole groups only", that group
  isn't installed from the stage. A Regional list that's free is still installed when its own
  group is complete.

### When a transaction counts as finished (all transactions, not only background)

**The commit point is one atomic rename of `Previous/` to `Previous.committed/`, as the last
step of the transaction.** `Previous/` existing at launch means the last transaction did not
commit, so restoring it is always right. Deleting `Previous.committed/` afterwards is cleanup,
and a kill partway through it is harmless. Today the commit is a recursive delete of
`Previous/`: a kill partway would leave a partial snapshot, and `FilterPipeline` ignores the
delete's error (`try?`), which under the new rule would silently undo a committed allowlist edit
at the next launch. Both change:

- `FilterStore.commit(_ snapshot:)` does the rename and flushes the container (`F_FULLFSYNC`, as
  `restore` does). If the rename fails, the transaction **didn't** commit: the caller restores,
  as for any other failure. Every snapshot user (`UpdateCoordinator`, `FilterPipeline`'s
  `inRollbackTransaction`, both reconciler paths) calls it in place of
  `discardRollbackSnapshot()`, never with `try?`.
- **Order inside each transaction:** snapshot → writes (rules, sidecars, `installed_filters.json`,
  and for an update the cached manifest and ETag) → mark every affected blocker in
  `pending_reloads.json` → empty `Staged/` (an update only) → **commit** → reload → record the
  reload results, which clears the successes. Marking before the commit closes a gap all three
  transaction types have today. A kill after the commit but before the reload would leave Safari
  on the old rules with nothing recording a reload owed. Now the committed marks make the next
  retry reload them. `FilterPipeline` transactions that reload inside the body (`.immediate`)
  move their reload after the commit, the order `UpdateCoordinator` already uses.
- **Everything the transaction writes is inside the snapshot.** Checked in the code: the cached
  manifest and its ETag (`manifest.json`), `pending_reloads.json`, `installed_filters.json`,
  `update_throttle.json` and `recompile_attempts.json` are written through `writeMetadata` into
  `Metadata/`, and the per-group sidecars (`<Group>.sources.json`) live in `Compiled/`. So a kill
  before the commit rolls the manifest and ETag back with the rules, and the next update fetches
  again instead of getting a `304` and keeping old rules. `Staged/` is the one thing outside it,
  by design (above). A test pins this list: it writes each of these files during a transaction
  that's abandoned, and checks that recovery puts every one back.

**Snapshot taken whole or not at all.** `snapshotForRollback` copies into `Previous.partial/` and
renames that to `Previous/` only once all three copies finish. A kill mid-copy leaves
`Previous.partial/`, which recovery just deletes, since nothing live has been written yet.

**A rollback that is itself killed.** `restore` swaps each saved directory into place one at a
time, so a kill between swaps leaves `Previous/` holding some old and some new directories, and
restoring it again would put the new ones back. To tell them apart, the snapshot writes a
`.snapshot-<uuid>` marker into each saved directory and records the UUID in
`Previous/snapshot-id`. After a swap the marker is in the live directory, before it in
`Previous/`. Recovery swaps only the directories whose marker is still in `Previous/`, then
deletes the markers from the live directories. A UUID per snapshot means a stray marker left by
an older snapshot never counts.

**Launch recovery.** First thing in the launch task, inside the gate, before the reconcile,
`FilterStore.recoverInterruptedTransaction()` runs:

- `Previous.partial/`: delete.
- `Previous.committed/` or `Previous.spent/`: delete.
- `Previous/`: restore it, finishing any rollback the markers show was interrupted.
- After a restore, **mark all four blockers in `pending_reloads.json` and reload all four.** The
  run may have reloaded some blockers before it died, so what Safari holds can differ from the
  restored files. Which ones were reloaded isn't recorded anywhere that survives the restore, and
  this path is rare, so reloading all four is simplest. Marking first means a reload that fails
  is retried like any other.

The gate is per process and the app is the only writer, so at launch no transaction can be
running, and any `Previous/` belongs to a dead one.

### Cancellation

- `Task.checkCancellation()` in `apply` before the snapshot and between groups, and in
  `prepare` between downloads. A cancellation after the snapshot throws into the existing catch,
  which restores every group.
- Both tasks' `expirationHandler` cancel the run. A compile already running doesn't stop, so for
  the processing task the launch restore above is what guarantees recovery if iOS kills the app.

### Scheduling

- SwiftUI's `.backgroundTask` has an `.appRefresh` case but no processing case, so both tasks
  are registered with `BGTaskScheduler.shared.register` in `ADBLXApp.init`, before the first
  scene, in one place (`BackgroundUpdates.register()`).
- `BackgroundUpdatePolicy` (pure, table-tested): next refresh `earliestBeginDate` = last success
  + 7 days (free) or 24 hours (Premium). After a network failure, now + 1 hour. A rejected
  manifest advances like a success, as at launch.
- The refresh request is submitted when the scene goes to the background, and at the end of each
  refresh run. The processing request is submitted when `prepare` completes a stage (every list
  the plan changes is staged).
- **Shared throttle:** one `lastSuccessAt`. A successful `prepare` (including a `304`) counts as
  a check, so a background check pushes the next launch check back 6 hours, and a launch check
  pushes the next background check back by the plan's interval. Installing what's staged at
  launch is never throttled.
- One `UpdateCoordinator` instance (the one `ADBLXApp` holds) serves all three triggers, so
  they join rather than race, and the gate orders them against reconcile, allowlist edits and the
  compiler recompile.

### Reload from the background

The processing task's install reloads the content blockers like any install. That
`SFContentBlockerManager.reloadContentBlocker` works while the app is in the background is
**assumed, not verified**: it's on the device check list. Until it's confirmed, the plan treats a
background install as "installed, reload pending". The reload results go through
`PendingReloads` as today, and the scene's next `.active` reloads any group still recorded there.
That's a small addition: today pending reloads are retried only by the next update run. If the
device check shows reloads fail in the background, the processing task skips the reload and
records every changed group as pending.

### Info.plist entries and background modes

The app target has no Info.plist file today: `project.yml` sets `GENERATE_INFOPLIST_FILE: YES`
and `INFOPLIST_KEY_*` build settings. There's no `INFOPLIST_KEY_` setting for
`BGTaskSchedulerPermittedIdentifiers`, so the app gets a small partial plist that Xcode merges
with the generated keys. It goes through XcodeGen's `info:` key, which writes the file and sets
`INFOPLIST_FILE`:

```yaml
  ADBLX:
    info:
      path: Config/ADBLX-Info.plist   # not under ADBLX/: a synced folder would also copy it as a resource
      properties:
        UIBackgroundModes: [fetch, processing]
        BGTaskSchedulerPermittedIdentifiers:
          - com.ADBLX.ADBLX.filter-refresh
          - com.ADBLX.ADBLX.filter-install
```

| Entry | Value | Why |
|---|---|---|
| `UIBackgroundModes` | `fetch` | Required for a `BGAppRefreshTask`. |
| `UIBackgroundModes` | `processing` | Required for a `BGProcessingTask`. |
| `BGTaskSchedulerPermittedIdentifiers` | `com.ADBLX.ADBLX.filter-refresh` | Without it, `register` and `submit` fail for that identifier. |
| `BGTaskSchedulerPermittedIdentifiers` | `com.ADBLX.ADBLX.filter-install` | Same. |

No entitlement is needed for either task. Both background modes count as one Background Modes
capability in App Store Connect, and a review note should say what they're for (on-device
blocklist updates; no location, audio or VoIP).

**Both build configurations.** `info:` sets `INFOPLIST_FILE` at the target level, so Debug and
Release use the same file. Unlike the tunnel, nothing here is configuration-specific. Two checks
make sure it stays that way:

- A unit test reads `Bundle.main.infoDictionary` in the test host (a Debug build) and checks both
  modes and both identifiers against the constants `BackgroundUpdates` registers.
- `Scripts/check-background-modes.sh <path to .app>` does the same with `PlistBuddy` on a built
  app. CI already builds Release for `check-release-no-dns.sh` (`.github/workflows/ci.yml`), so
  it runs this on that Release app next to the DNS check. The unit test covers Debug.

## Battery and data cost

- **A typical refresh:** one network wake-up for one HTTPS manifest request, almost always a
  `304` with no body. No signature fetch, download or compile.
- **When a list changed** (upstream lists change about weekly): one signature fetch and the
  changed lists only (EasyList is 2.06 MB; all four total about 5.3 MB), then nothing more until
  the phone is charging, when the processing task compiles only the changed groups.
- **Frequency:** no more than iOS grants: at most about weekly for free and daily for Premium,
  often less for a rarely used app. iOS skips both tasks in Low Power Mode, and when the user
  turns Background App Refresh off for the app.
- **Verify on the device before TestFlight:** the Energy Log instrument across a day's normal use
  with refresh enabled and at least one forced refresh with a changed list. Expect the refresh to
  show as a brief network wake-up and the compile only while charging.

## Tasks

Each ends green with a test that fails without it. Task 1 is independent of background work and
lands first.

1. **The commit point and launch recovery.** `FilterStore.commit(_:)` (rename to
   `Previous.committed/`, flush) replaces `discardRollbackSnapshot()` in all four snapshot users,
   never with `try?`; the in-transaction order above, including pending-reload marks before the
   commit and `.immediate` reloads moved after it; `Previous.partial/`; the snapshot markers;
   `recoverInterruptedTransaction()` in the launch task inside the gate. A "kill" in tests is a
   test-only hook (`TransactionStopPoint`) that suspends the transaction at a named step and
   never resumes it. The test then opens a second `FilterStore`, with its own gate, on the same
   container, as the next launch would. Tests, each written to fail first:
   - **Killed after the reload, before the commit** (a `FilterPipeline` transaction reloading
     `.immediate`, and an update whose manifest and ETag were already written): the next launch
     restores `Compiled/`, `Metadata/` and `Filters/` byte-for-byte, reloads all four blockers
     (a recording reloader), and the cached manifest and ETag are the old ones.
   - Killed after the commit, before the reload: nothing is restored, and the affected blockers
     are in `pending_reloads.json`, so the next retry reloads them.
   - Killed mid-snapshot (`Previous.partial/`): deleted, live state untouched.
   - Killed during a rollback, after the first of three swaps: recovery finishes the other two
     and every directory matches the pre-transaction state, with no marker left in a live
     directory.
   - `Previous.committed/` or `Previous.spent/` at launch: deleted, live state untouched.
   - The commit rename fails (an injected `swapPaths`/move failure): the transaction restores
     and reports failure, and nothing is left for launch to undo.
   - Every file listed under "Everything the transaction writes is inside the snapshot" is
     written during an abandoned transaction and comes back after recovery.
   - Order: recovery runs before the reconcile in the launch sequence (a stub that records the
     order).
2. **Spike:** time `prepare` (every list changed) and the compile separately, on the simulator;
   the owner times both on the iPhone 14. Confirms the 20-second target for the refresh, or
   switches to one list per run.
3. **`prepare` / `apply` split** with staging. Tests:
   - A `304` stages nothing. A staged update applies the same result as `run()`. The cached
     manifest and ETag are unchanged until `apply` commits.
   - Tied to the manifest: a staged payload whose SHA-256 doesn't match the stored manifest's
     entry (altered after staging) discards the stage and leaves every group as it was. A stage
     whose stored manifest fails verification again (a corrupted signature file) is discarded.
     A stage from a manifest the cache has since reached or passed is discarded.
   - Superseded: staging under a newer manifest keeps a file whose SHA-256 the new manifest
     still names, deletes one it doesn't, and leaves one `stage.json`. After a successful
     `apply`, `Staged/` is empty. A kill mid-download leaves unnamed payloads that the next open
     deletes.
   - Whole groups: with one of a group's two changed lists staged, `apply` installs nothing in
     that group, installs another group that's complete, keeps the partial stage, and doesn't
     save the manifest to the cache. Staging the second list then installs the group.
   - Lapse: a premium list staged before a lapse isn't installed after it (re-plan), and the
     reconciler deletes its payload and entry. A free list staged beside it still installs.
4. **Cancellation:** cancel during the second of three group installs; every group restored
   byte-for-byte, no manifest or ETag saved, `CancellationError` thrown. Cancel during
   `prepare`: nothing written outside `Staged/`.
5. **`BackgroundUpdatePolicy` and shared throttle:** table tests per plan; a background check
   makes the next launch check skip, and the reverse; staged work installs at launch regardless
   of the throttle.
6. **Registration and scheduling:** both tasks registered, refresh submitted on `.background`
   and after each run, processing submitted only after a complete stage, expiration cancels; the
   pending-reload retry at launch (after recovery) and on `.active`. `project.yml` gains the
   `info:` entry above; the `Bundle.main.infoDictionary` test; `check-background-modes.sh` with
   its own test cases (as `check-release-no-dns.sh` has) and a CI step on the Release app.
7. **Copy and docs:** paywall strings, Home plan card string, PRD §5.1 row, the gotcha closed,
   `TECHNICAL_OVERVIEW.md` update flow, and how to force each task from the debugger
   (`e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
   _simulateLaunchForTaskWithIdentifier:@"…"]`) in the device check list.

## Device checks (owner)

- Force the refresh with a changed list: the lists are staged, nothing is installed, the
  processing request is pending.
- Force the processing task: rules install, and whether Safari picks them up without opening the
  app (the reload question above).
- Kill the app from the debugger during a forced processing task's compile; open it: the rules
  are those from before the update (Safari included, after the launch reload), and the update
  installs again at the next check.
- Energy Log over a day of normal use.
- Background App Refresh off for the app: neither task runs, launch updates still work.

## Not in this plan

- Push-triggered updates (PRD Open Question 4).
- Background `URLSession` downloads; only if one-list-per-run still doesn't fit.
