# Background filter updates (BGAppRefreshTask)

Branch: `feat/background-updates`, off `feat/plan-state-downgrade` at `908f3df`. For review
before building. Closes the gotcha "Pre-launch: the PRD promises free weekly auto-updates, but
nothing schedules them".

## What exists today

- The only automatic update is at launch: `AutomaticUpdate.runIfDue` from `ADBLXApp`'s
  detached launch task, throttled to 6 hours by `UpdateThrottle` (`update_throttle.json`,
  one `lastSuccessAt`). A rejected manifest advances the throttle; any other failure doesn't.
- `UpdateCoordinator.run()` joins an in-flight run on the same instance, and every
  transaction (update, reconcile, allowlist sync, compiler recompile) takes
  `FilterTransactionGate.shared`.
- The coordinator never checks for cancellation. Cancelling its task doesn't stop a compile;
  a process killed mid-transaction leaves `Previous/`, which the next snapshot discards, and
  drift repair recompiles any group whose sidecar no longer matches.
- PRD §5.1: "Automatic filter updates: Free ✅ (weekly); Premium ✅ (frequent; push-triggered
  planned)". The paywall lists **Background Updates** as a Premium feature ("Blocklists stay
  fresh automatically…").

## Decision for review: who gets background updates

The PRD and the paywall disagree. Two options:

- **(A) Free weekly, Premium daily.** Matches the PRD. The paywall item becomes "Daily
  background updates", since free users get weekly ones too.
- **(B) Premium only.** Matches the paywall. The PRD's free row changes to "when you open the
  app" (what free users get today, at most every 6 hours).

Recommendation: **(A)**. A weekly background check costs a free user one small request most
weeks, and it keeps the PRD's promise for users who rarely open the app, which is exactly when
their lists go stale. The paywall copy change is one string.

## Design

### Scheduling

- One identifier, `com.ADBLX.ADBLX.filter-refresh`, registered with SwiftUI's
  `.backgroundTask(.appRefresh(...))` on the `WindowGroup` scene (no `AppDelegate` needed).
- A `BGAppRefreshTaskRequest` with `earliestBeginDate` = last success + the plan's interval
  (A: Premium 24 h, free 7 days), submitted when the scene goes to the background and at the
  end of every background run. `earliestBeginDate` is a floor: iOS runs it when its usage
  model allows, and may run it later or not at all for a rarely used app. "Daily" is best
  effort, and the copy shouldn't promise an exact time.
- `BackgroundUpdatePolicy` (pure): given the plan and the last success, the next
  `earliestBeginDate`, and whether a run that started is due. Tested without the scheduler.

### Running

- The background handler calls the app's **one** `UpdateCoordinator` (the instance
  `ADBLXApp` already holds), so a launch run and a background run in the same process join
  rather than race; the gate orders them against reconcile, allowlist edits and the compiler
  recompile.
- It runs the same steps as launch, in order: entitlement refresh, reconcile, compiler
  recompile, then the update if the background policy says it's due. Not the bundled
  bootstrap or onboarding work, which belong to a foreground launch.
- **Shared throttle:** one `lastSuccessAt` for both triggers. A successful background run
  pushes the next launch check back 6 hours, and a launch run pushes the next background run
  back by the plan's interval. A rejected manifest advances it in both, as today.
- **Network failure in the background:** reschedule with `earliestBeginDate` = now + 1 hour,
  not the full interval. iOS rate-limits it anyway, so there's no retry storm.

### Time budget and cancellation

A `BGAppRefreshTask` gets about 30 seconds. A check with a `304` takes well under a second; a
changed list means downloading a few MB and compiling that group.

- Add cooperative cancellation to `UpdateCoordinator.runTransaction`: `Task.checkCancellation()`
  before the snapshot and between groups. A cancellation after the snapshot throws into the
  existing catch, which restores every group, exactly like any other mid-install failure.
- The task's `expirationHandler` cancels the run. Whatever finished before is either committed
  whole or rolled back whole.
- **Spike first:** measure a full update with every list changed, on the simulator and (owner)
  on the iPhone 14. If it regularly exceeds about 25 seconds, the background refresh only
  checks and downloads, and the install happens at the next launch from the downloaded files;
  or a `BGProcessingTask` (runs on charge, minutes long) does the install. Decide after the
  numbers; the default plan assumes it fits.

### Reload

`SFContentBlockerManager.reloadContentBlocker` from a background run is expected to work (it
doesn't need UI). Not verified: it goes on the device check list. A failed reload is already
retried through `pending_reloads.json`.

### Info.plist (through `project.yml`, never by hand)

```yaml
UIBackgroundModes: [fetch]
BGTaskSchedulerPermittedIdentifiers: [com.ADBLX.ADBLX.filter-refresh]
```

(`processing` is added to `UIBackgroundModes` only if the spike moves the install to a
`BGProcessingTask`.) A test reads the built `Info.plist` and checks both, so the identifier in
code and in the plist can't drift.

## Battery and data cost

- **A typical run:** one HTTPS request for the manifest, almost always a `304` with no body,
  plus a radio wake-up of a few seconds. No signature fetch, download or compile.
- **When a list changed** (upstream lists change about weekly): one signature fetch, the
  changed lists (EasyList is 2.06 MB; all four total about 5.3 MB), and compiling only the
  changed groups.
- **Frequency:** at most what iOS grants: under (A), about one run a day for Premium and one a
  week for free, often less for apps used rarely. iOS also skips background refresh in Low
  Power Mode and when the user turns Background App Refresh off for the app.
- **Expected impact:** negligible next to a foreground launch, which already does the same
  check. Verify on device: Xcode's Energy report or `Energy Log` across a day with a forced
  refresh, before TestFlight.

## Tasks

Each ends green, with a test that fails without it.

1. **Spike:** time a full update (every list changed) on the simulator; the owner times it on
   the iPhone 14. Decide fit vs. download-only (above).
2. **Cancellation in `runTransaction`:** checks before the snapshot and between groups. Test:
   cancel during the second of three group installs; every group restored byte-for-byte, no
   manifest or ETag saved, the error is `CancellationError`.
3. **`BackgroundUpdatePolicy`:** next `earliestBeginDate` per plan and last success; due or not;
   network failure gives now + 1 hour; a rejection advances like success. Table tests.
4. **Shared throttle:** a background success makes the next launch check skip, and the
   reverse. Through `AutomaticUpdate` with a stub clock.
5. **Registration and scheduling:** `.backgroundTask(.appRefresh)` on the scene, submit on
   `.background` and after each run, expiration cancels. `project.yml` gains the two plist
   keys; a test checks the built `Info.plist` and that the identifier matches the code.
6. **Copy and docs** (after the decision): paywall string, PRD §5.1 row, the gotcha closed,
   `TECHNICAL_OVERVIEW.md` update flow, and how to force a run from the debugger
   (`_simulateLaunchForTaskWithIdentifier:`) in the device check list.

## Device checks (owner)

- Force a background refresh from the debugger with a changed list: rules install, Safari
  reloads, nothing visible changes in the app.
- Energy over a day with refresh enabled.
- Background App Refresh turned off for the app: nothing runs, and launch updates still work.

## Not in this plan

- Push-triggered updates (PRD Open Question 4).
- Background downloads with `URLSessionConfiguration.background`. Only needed if the spike
  shows downloads don't fit; then planned separately.
