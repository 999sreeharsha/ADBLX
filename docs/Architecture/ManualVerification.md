# Manual Verification

Manual checklists for behavior that isn't automated in CI — either because it requires Safari/extension registration (not scriptable in CI) or because automating it now would cost more than it proves at this stage of the project. Update in place as new manual-only surfaces appear.

## `ADBLXAdsBlocker` Content Blocker pipeline (Sprint 0 Commit 5)

Verifies each stage of the App Group → Content Blocker → Safari pipeline independently, not just the end result.

1. Install the app (fresh install, or after clearing the App Group container — see Task 4's test for how to locate/clear `Rules/Ads.json`).
2. Launch the app — this copies rules into the App Group and requests a reload. **Expected at this point:** the reload request may fail or no-op, because Safari doesn't know about the extension yet — that's expected, not a bug (see Task 5's code comment).
3. Confirm `Rules/Ads.json` appears in the App Group container on disk (`xcrun simctl get_app_container <UDID> com.ADBLX.ADBLX groups`, then check `Rules/Ads.json` exists inside that path).
4. Enable `ADBLXAdsBlocker` in Safari → Settings → Extensions (on device or simulator).
5. Relaunch the app — the file copy is now a no-op (idempotent), but the reload request fires again, and this time Safari has the extension registered.
6. Confirm the `Bootstrap`-category log line from this second launch reports the reload succeeded (Console.app, filter by subsystem `com.ADBLX.ADBLX`, category `Bootstrap`).
7. Visit a page that issues a request matching one of the synthetic rules (e.g. a test page that loads `https://ads1.example.com/...`).
8. Confirm the matching request is blocked (Safari's Page Information → "X trackers blocked" or equivalent, or a network inspector showing the request never completing).

Every step has a deterministic cause — no step relies on hoping an earlier reload happened to land at the right time.

## Fallback verification

9. With the App Group's `Rules/Ads.json` deliberately removed (see Task 4's test for the removal command), confirm `ADBLXAdsBlocker` still produces valid output by falling back to its bundled `Resources/blockerList.json` — re-run steps 4–8 and confirm blocking still works.

## Last verified

| Date | Result | Notes |
|---|---|---|
| 2026-07-15 | PARTIAL | Steps 1–3 verified programmatically (app launched via `xcrun simctl launch`, `Rules/Ads.json` confirmed present, valid, and matching the bundled source — 70 rules). Along the way, discovered and fixed two bugs blocking this checklist entirely: extensions weren't embedded in the app bundle (`project.yml` had no `dependencies`/`embed: true` for any of the 6 extension targets — `PlugIns/` was empty), and extension bundle IDs weren't nested under the app's (`com.ADBLX.ADBLXAdsBlocker` → `com.ADBLX.ADBLX.AdsBlocker`), which made `xcrun simctl install` fail outright with "Mismatched bundle IDs" once embedding was fixed. After both fixes, `pluginkit -m -p com.apple.Safari.content-blocker` confirms all 4 Content Blockers (including `com.ADBLX.ADBLX.AdsBlocker`) are registered as extension points at the OS level. Steps 4–9 still require enabling the extension in Safari's GUI (Settings → Extensions) and visually confirming blocked requests, which cannot be driven from the CLI — pending manual walkthrough by a human, but should now be unblocked. |
