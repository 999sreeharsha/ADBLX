# Background filter updates (BGAppRefreshTask + BGProcessingTask)

Branch: `feat/background-updates`, off `feat/plan-state-downgrade` at `9e9d20a`. Revised after
review (second draft). Closes the gotcha "Pre-launch: the PRD promises free weekly auto-updates,
but nothing schedules them".

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
`URLSession` downloads. That's still one task, just resumed.

### Staging (`UpdateCoordinator` split in two)

- `prepare() -> PreparedUpdate?`: the current steps up to and including download and verify,
  without the snapshot. It writes `Staged/staged.json` (the verified manifest, its ETag and
  signature-verified flag, the plan's install and remove lists) plus each verified payload. It
  doesn't save the manifest or ETag to the cache: a launch must not get a `304` for an update
  that hasn't been installed. Returns `nil` on a `304` or when nothing changed.
- `apply(_:)`: under the gate, in a rollback transaction. It checks each staged payload's checksum
  against the staged manifest again, then **plans again** against the installed lists and the
  entitlement as they are now, since a lapse or purchase may have happened in between. It
  installs, then saves the manifest and ETag to the cache. It discards a staged update whose
  `manifestVersion` isn't newer than the cached one, or that has any file missing.
- `run()` stays `prepare()` then `apply()` in one gate hold, so the foreground update sheet and
  tests behave as today.
- `Staged/` is outside the snapshot: a rollback leaves it in place, and a later run replaces it.
  It's removed after a successful `apply`, or when discarded.

### Recovering a transaction killed partway (all transactions, not only background)

- **Mark the snapshot complete.** `snapshotForRollback` copies into `Previous.partial/` and
  renames that to `Previous/` only once all three copies finish. A `Previous/` therefore always
  holds a whole pre-transaction state. Killed mid-copy leaves `Previous.partial/`, which is just
  deleted, since nothing live has been written yet.
- **Restore at launch.** First thing in the launch task, inside the gate, before reconcile:
  `FilterStore.recoverInterruptedTransaction()`. If `Previous/` exists, no transaction can be
  running (the gate is per process and the app is the only writer), so the last one died before
  committing or before discarding its snapshot. `restore` puts every directory back. If it died
  after committing but before discarding, this reverts a finished update to the consistent state
  before it, and the reverted cached manifest makes the next update fetch it again. That's
  wasted work, never a wrong state.
- `Previous.spent/` at launch (a restore that stopped partway) can't be restored; it's deleted,
  and reconcile's drift repair and the corrupt-metadata recovery handle what's left, as today.
- `PendingReloads` is recorded after the restore, so Safari reloads the restored rules.

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
  refresh run. The processing request is submitted whenever `prepare` stages something.
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

### Info.plist (through `project.yml`, never by hand)

```yaml
UIBackgroundModes: [fetch, processing]
BGTaskSchedulerPermittedIdentifiers:
  - com.ADBLX.ADBLX.filter-refresh
  - com.ADBLX.ADBLX.filter-install
```

A test reads the built `Info.plist` and checks both modes and both identifiers against the
constants in code.

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

1. **Launch recovery of an interrupted transaction.** `Previous.partial/` then rename;
   `recoverInterruptedTransaction()` in the launch task inside the gate. Tests, each written to
   fail first:
   - Snapshot taken, live state changed, then a new `FilterStore` on the same container (the
     next launch) recovers: `Compiled/`, `Metadata/`, `Filters/` byte-for-byte as before the
     snapshot.
   - A `Previous.partial/` (killed mid-copy) is deleted and live state untouched.
   - No `Previous/`: nothing changes.
   - `Previous.spent/`: deleted, live state untouched.
   - Ordering: recovery runs before reconcile in the launch sequence (a stub that records the
     order).
2. **Spike:** time `prepare` (every list changed) and the compile separately, on the simulator;
   the owner times both on the iPhone 14. Confirms the 20-second target for the refresh, or
   switches to one list per run.
3. **`prepare` / `apply` split** with staging. Tests: a `304` stages nothing; a staged update
   applies the same result as `run()`; the cached ETag is unchanged until `apply`; a staged
   update older than the cache is discarded; a premium list staged before a lapse isn't
   installed after it (re-plan); a payload altered on disk after staging fails `apply` and
   leaves every group as it was.
4. **Cancellation:** cancel during the second of three group installs; every group restored
   byte-for-byte, no manifest or ETag saved, `CancellationError` thrown. Cancel during
   `prepare`: nothing written outside `Staged/`.
5. **`BackgroundUpdatePolicy` and shared throttle:** table tests per plan; a background check
   makes the next launch check skip, and the reverse; staged work installs at launch regardless
   of the throttle.
6. **Registration and scheduling:** both tasks registered, refresh submitted on `.background`
   and after each run, processing submitted after staging, expiration cancels; the
   pending-reload retry on `.active`. `project.yml` gains the plist keys; the built-`Info.plist`
   test.
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
  are those from before the update, and the update installs again from the stage or the next
  check.
- Energy Log over a day of normal use.
- Background App Refresh off for the app: neither task runs, launch updates still work.

## Not in this plan

- Push-triggered updates (PRD Open Question 4).
- Background `URLSession` downloads; only if one-list-per-run still doesn't fit.
