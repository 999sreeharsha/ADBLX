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

9. With the App Group's `Rules/Ads.json` deliberately removed (see Task 4's test for the removal command), confirm `ADBLXAdsBlocker` still produces valid output by falling back to its bundled `Resources/blockerList.json` — re-run steps 7–8 and confirm blocking still works. **Do not relaunch the app to trigger this** — `ContentBlockerBootstrap.reloadIfNeeded()` always recreates `Rules/Ads.json` before requesting a reload (see Task 5's code comment), so an app relaunch can never actually exercise the fallback. Instead, toggle `ADBLXAdsBlocker` off then on in Safari → Settings → Extensions, which makes Safari re-invoke the extension directly, independent of the app. Confirm via `xcrun simctl spawn <UDID> log show --predicate '(process == "ADBLXAdsBlocker")' --info --last 3m`, filtering for the `AppGroup`-category line — it should read "App Group rules unavailable, falling back to bundled blockerList.json". Then restore `Rules/Ads.json` and repeat the toggle to confirm the App Group path (`Using App Group rules at ...`) resumes.

## Last verified

| Date | Result | Notes |
|---|---|---|
| 2026-07-15 (AM) | PARTIAL | Steps 1–3 verified programmatically (app launched via `xcrun simctl launch`, `Rules/Ads.json` confirmed present, valid, and matching the bundled source — 70 rules). Along the way, discovered and fixed two bugs blocking this checklist entirely: extensions weren't embedded in the app bundle (`project.yml` had no `dependencies`/`embed: true` for any of the 6 extension targets — `PlugIns/` was empty), and extension bundle IDs weren't nested under the app's (`com.ADBLX.ADBLXAdsBlocker` → `com.ADBLX.ADBLX.AdsBlocker`), which made `xcrun simctl install` fail outright with "Mismatched bundle IDs" once embedding was fixed. After both fixes, `pluginkit -m -p com.apple.Safari.content-blocker` confirms all 4 Content Blockers (including `com.ADBLX.ADBLX.AdsBlocker`) are registered as extension points at the OS level. |
| 2026-07-15 (PM, 1) | PASS (steps 1–8) | User manually enabled `ADBLXAdsBlocker` in Safari → Settings → Extensions on the iPhone 17 Pro simulator. Relaunched the app; `log stream` on subsystem `com.ADBLX.ADBLX` captured `[Bootstrap] Reload succeeded`. User then navigated Safari to `https://ads1.example.com/test` and got Safari's native "The content was blocked by a Content Blocker" error page — direct confirmation the rule matched and the request was blocked before ever reaching the network. |
| 2026-07-15 (PM, 2) | PASS (step 9 — fallback) | `ContentBlockerRequestHandler` had no logging at all going into this test — added `os.Logger` under category `AppGroup`, initially reusing the `Bundle.main.bundleIdentifier` pattern from `ContentBlockerBootstrap`. That pattern is wrong inside an extension (`Bundle.main` there resolves to the extension's own bundle ID, `com.ADBLX.ADBLX.AdsBlocker`, not the app's), so it had to be hardcoded to `"com.ADBLX.ADBLX"` for Console/log-stream filtering to actually find it. With that fixed: removed `Rules/Ads.json` from the App Group, toggled the extension off/on in Safari (relaunching the app doesn't work for this — see step 9's note), and confirmed via `log show --predicate '(process == "ADBLXAdsBlocker")'` the exact line `[com.ADBLX.ADBLX:AppGroup] App Group rules unavailable, falling back to bundled blockerList.json`. Safari continued blocking `ads1.example.com` throughout (identical rule content in both sources). Restored `Rules/Ads.json`, repeated the toggle, and confirmed `[com.ADBLX.ADBLX:AppGroup] Using App Group rules at .../Rules/Ads.json` — the App Group path resumed. All 9 steps of this checklist are now fully verified. **Sprint 0 is complete.** |
