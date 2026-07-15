# Sprint 0 — Commit 5: Runtime Validation Design

**Project:** ADBLX (SHIELD) — iOS Ad Blocker
**Status:** Approved (Ready for Implementation)
**Parent spec:** `docs/superpowers/specs/2026-07-14-sprint0-bootstrap-design.md`

## Goal

Prove that the foundation built in Commits 1–4 actually works at runtime: the App Group round-trip, the Content Blocker reload path, and a performance/observability baseline. This is Sprint 0's last commit and is deliberately scoped as **validation only** — no new product architecture.

- **Commit 3:** target topology.
- **Commit 4:** permissions and infrastructure (App Groups, CI).
- **Commit 5 (this one):** runtime validation — does the thing Commits 1–4 built actually work.

## Explicitly out of scope

RuleCompiler, filter/manifest downloads, a CDN client, background tasks, StoreKit, Settings screens, DNS filtering, any `ADBLXPacketTunnel` work. If a later need surfaces any of these, it belongs in a future sprint, not here.

## 1. Bundled rules

`Extensions/ADBLXAdsBlocker/Resources/blockerList.json` is replaced with **50–100 hand-authored, original synthetic rules** — e.g. `ads.example.com`/`tracker.example.net`-style patterns invented for this purpose. Explicitly not sourced from EasyList, AdGuard, OISD, HaGeZi, or any other existing filter list, and not the 1–3K scale mentioned in early scoping — that number belongs to the first real RuleCompiler milestone, not Sprint 0. Rule count doesn't change what's being validated (JSON parsing, App Group copy, extension read, `reloadContentBlocker()`, Safari acceptance); a smaller set exercises the identical pipeline with zero licensing exposure since none of `agent.md`'s "GPL/CC-BY-SA — attribution + legal review required before shipping" constraint applies to original content.

Only `ADBLXAdsBlocker` is touched. `ADBLXPrivacyBlocker`, `ADBLXAnnoyancesBlocker`, `ADBLXRegionalBlocker` are untouched, still bundling `[]` — Commit 5 proves the pipeline once; replicating it to the other three is future work, not this commit's job.

## 2. `ContentBlockerBootstrap` (new type, app target)

A small coordinator in `ADBLX/ContentBlockerBootstrap.swift`, kept separate from `ADBLXApp` so app startup doesn't accumulate bootstrap logic directly (and so this naturally evolves into a `FilterUpdateManager`/`RuleCompiler`/`ReloadManager` pipeline later without an `ADBLXApp` rewrite):

```swift
enum ContentBlockerBootstrap {
    static func ensureInitialRulesInstalled() -> Bool
    static func reloadIfNeeded()
}
```

- `ensureInitialRulesInstalled()` — idempotent, not run-every-launch: checks whether `Rules/Ads.json` already exists in the App Group container. If it does, does nothing and returns `false`. If it doesn't, copies the bundled `blockerList.json` into `Rules/Ads.json` atomically (write to `Rules/Ads.json.tmp`, then `FileManager.replaceItemAt` / rename) and returns `true`. This is the one-time install path; the future manifest-version-comparison path (installed version vs. manifest version → copy → reload) is explicitly future work, not built here — only the "does the file exist yet" check is implemented now.
- `reloadIfNeeded()` — calls `ensureInitialRulesInstalled()` (the copy stays idempotent), then **unconditionally** calls `SFContentBlockerManager.reloadContentBlocker(withIdentifier: "com.ADBLX.ADBLXAdsBlocker")` regardless of whether a copy just happened. The completion handler logs success or the specific `Error` on failure — never swallowed.

  **Why unconditional, revised from the original design:** the original "reload only on first install" design has a sequencing bug — first install happens before the user has ever enabled the extension in Safari, so the one guaranteed reload attempt fires when Safari doesn't yet know the extension exists, and there is no second trigger for when the user later enables it (Apple exposes no "extension was just enabled" callback). Requesting a reload on every launch is the only observable event available before a manifest/update pipeline exists, so it stands in for that missing signal. **This is Sprint-0-only validation behavior, not the intended production policy** — the code carries a comment saying so, and Sprint 1's manifest/version-comparison logic replaces it with "reload only when the manifest version changed."
- Invoked once per launch from `ADBLXApp` inside a `Task` (off the main actor) attached to `WindowGroup`'s `.task` modifier — not on a timer, not on every view redraw, not gated behind any new UI.

## 3. `ContentBlockerRequestHandler` migration (`ADBLXAdsBlocker` only)

`beginRequest(with:)` tries `Rules/Ads.json` in the App Group container first; if `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` resolution or the file read fails for any reason, it falls back to the bundled `Resources/blockerList.json` — the same real production lifecycle Commit 3 established, just with a resilient source. This fallback is permanent behavior, not a Sprint-0-only shim: it also covers the legitimate first-launch race where Safari asks the extension to reload before the app has ever run.

Requires its own `AppGroup.swift` inside `Extensions/ADBLXAdsBlocker/` — a second tiny duplicate of the one-line identifier constant (app target + this one extension only). Consistent with Commit 4's call: duplicate only where a real, current need exists; still no `Packages/ADBLXShared` linkage, still no ADR-0003 written. If a third target needs it, that's the trigger to reconsider, not before.

## 4. Logging

No logging infrastructure exists in the codebase yet (confirmed — greenfield). Commit 5 establishes the convention going forward using `os.Logger`, subsystem `Bundle.main.bundleIdentifier` (`com.ADBLX.ADBLX`), with three categories introduced now:

- `Bootstrap` — `ContentBlockerBootstrap`'s copy/reload lifecycle.
- `AppGroup` — container resolution and file I/O success/failure, used by both the app and `ADBLXAdsBlocker`.
- `MetricKit` — payload receipt (see below).

Every `Logger` call site states what happened, not just that something happened (e.g. "copied Ads.json to App Group" / "reload succeeded" / "reload failed: \(error)"), so a future investigation into update failures has a real trail.

## 5. MetricKit

A minimal `MetricsSubscriber: NSObject, MXMetricManagerSubscriber` in the app target, registered once via `MXMetricManager.shared.add(subscriber)` at launch (alongside the `ContentBlockerBootstrap` call). `didReceive(_ payloads: [MXMetricPayload])` only logs that a payload arrived (count, timestamp) via the `MetricKit` category — no parsing of individual metrics, no persistence, no upload. Exactly the minimal receiver scoped originally; no changes from the initial proposal.

## 6. Performance baseline

`Performance/Baselines.md` is populated with:
- Cold launch time (Instruments Time Profiler, manual capture, recorded as a single baseline number with the device/simulator used).
- The 7-target `xcodebuild` build-time baseline — already informally captured as a one-off in Commit 3's acceptance criteria; formalized here as a tracked, dated baseline.
- A note on `ADBLXAdsBlocker`'s memory footprint (Instruments Allocations, manual), checked against the ~6MB Content Blocker extension limit noted in `agent.md`'s hard constraints.

This is a documentation/measurement task, not new product code — no automated performance test is added in this commit.

## 7. Manual Safari verification (not automated)

A documented manual checklist (in `Performance/Baselines.md` or a new `docs/Architecture/ManualVerification.md` — decided at plan-writing time), verifying each stage of the chain independently rather than just the end result:

1. Install the app.
2. Launch the app — this copies rules into the App Group and requests a reload (the reload is expected to report failure or be a no-op at this point, since Safari doesn't know about the extension yet; that's expected, not a bug).
3. Confirm `Rules/Ads.json` appears in the App Group container (inspect on disk).
4. Enable `ADBLXAdsBlocker` in Safari's Extensions settings.
5. Relaunch the app — the copy is now a no-op (idempotent), but the reload request fires again, and this time Safari has the extension registered.
6. Confirm the `Bootstrap` category logs report this second reload succeeded.
7. Visit a page that issues a request matching one of the synthetic rules.
8. Confirm the matching request is blocked.

Every step now has a deterministic cause — no step relies on "hoping" a prior reload happened to land at the right time.

This stays manual and undocumented-as-CI, consistent with Commit 4's "no UI worth testing yet" policy — automating Safari verification now would cost far more than it proves at this stage.

## Acceptance criteria

1. `ADBLXAdsBlocker/Resources/blockerList.json` contains 50–100 original synthetic rules; valid Safari Content Blocker JSON (`plutil`/JSON-schema check as applicable).
2. `ContentBlockerBootstrap.ensureInitialRulesInstalled()` is idempotent: first call copies and returns `true`; every subsequent call (same container state) returns `false` and performs no I/O.
3. `ContentBlockerBootstrap.reloadIfNeeded()` calls `SFContentBlockerManager.reloadContentBlocker(withIdentifier:)` on every launch, independent of whether rules were freshly installed; the completion result (success or the specific error) is logged via the `Bootstrap` category, never swallowed. A code comment states this is Sprint-0-only behavior pending Sprint 1's manifest-driven reload logic.
4. `Rules/Ads.json` exists in the App Group container after first app launch, with content identical to the bundled snapshot.
5. `ADBLXAdsBlocker` successfully loads rules from the App Group when present, and falls back to its bundle resource when the App Group file is absent (verified by deliberately clearing the App Group container and confirming the extension still produces valid output).
6. `ADBLXPrivacyBlocker`, `ADBLXAnnoyancesBlocker`, `ADBLXRegionalBlocker` remain unchanged — still bundle `[]`, no App Group read added.
7. `MetricsSubscriber` is registered at launch; a manually triggered MetricKit payload (or waiting for a real one) produces a `MetricKit`-category log line.
8. `Performance/Baselines.md` contains cold launch time, the 7-target build baseline, and the `ADBLXAdsBlocker` memory note, each dated.
9. Manual Safari verification checklist is written and has been walked through at least once with a passing result.
10. All existing tests (`ADBLXTests`, including Commit 4's `AppGroupTests`) and CI continue to pass.

## Performance & battery

Main-thread impact: startup only orchestrates `Task { }`-dispatched work; actual file I/O happens off the main actor. Memory: 50–100 rules is a negligible JSON payload. Disk: one atomic write per install, zero on subsequent launches (the copy stays idempotent). Battery: `reloadContentBlocker()` is called once per launch, revised from the original "first install only" design after Stage 1 of an ABORT review surfaced a sequencing bug — the one guaranteed reload attempt otherwise fires before Safari has ever registered the extension, with no second trigger for when the user later enables it. This is explicitly Sprint-0-only: Safari's reload call is cheap when the rule set hasn't changed, and at ~100 rules this is immaterial, but it does not match the eventual production model (manifest-version-driven reload) and is documented in code as temporary, to be replaced in Sprint 1.

## What's deliberately not here

- Manifest-version-comparison logic for future rule updates — only "does `Rules/Ads.json` exist yet" is implemented; version comparison is future work once a manifest format exists.
- Checksum/hash comparison of the installed vs. bundled file to detect corruption or manual tampering during development — a reasonable low-cost enhancement, but it's a step toward the manifest-version-comparison logic above and was deliberately left for Sprint 1 rather than blurring Commit 5's "existence check only" scope.
- `Packages/ADBLXShared` linkage / ADR-0003 — still deferred; `AppGroup.swift` is duplicated into exactly 2 places (app, `ADBLXAdsBlocker`), not shared.
- Migrating `ADBLXPrivacyBlocker`/`ADBLXAnnoyancesBlocker`/`ADBLXRegionalBlocker` to the App Group — proven once with `ADBLXAdsBlocker`, replication is future work.
- Automated Safari/extension UI testing — manual checklist only.
- Any MetricKit payload parsing, aggregation, persistence, or upload.
