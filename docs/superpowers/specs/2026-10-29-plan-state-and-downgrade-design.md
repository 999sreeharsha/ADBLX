# Plan State (FR-16) + Premium Downgrade (FR-17) — Design

Status: **Draft for review (Phase 1 — no code written)**. 2026-10-29.
Authoritative monetization source: `docs/Architecture/PD-01-monetization-and-trial.md`
(supersedes PRD §9; 15-day universal app-managed trial, final).

## 1. Problem

Entitlement loss (trial expiry, subscription lapse, refund/revocation) changes
only a boolean in memory. Nothing removes premium *enforcement artifacts* that
are already on disk, and no UI shows plan state. Free users may also be getting
premium rules from the bundle. This spec makes "not entitled" actually change
what the extensions do, then surfaces one derived `PlanState` in the UI.

## 2. Verified findings (code read 2026-10-29)

| # | Question | Finding | Consequence |
|---|---|---|---|
| F1 | Bundled snapshot free-only? | **No — bug.** `FilterPipeline.installBundledSnapshotIfNeeded()` installs `fanboy-annoyances` into `.annoyances` unconditionally (and Ads, Privacy). `Resources/Filters/fanboy-annoyances.txt` is bundled. | A fresh free/expired install gets cookie-banner rules. Bundle must install Ads + Privacy only. Bootstrap is also gated only on `ManifestStore.load()==nil` / `Ads.json > 10 KB`, so an existing install's Annoyances is never revisited by it. |
| F2 | Premium manifest entries | `backend/public/manifest.json`: `easylist` (ads, free), `easyprivacy` (privacy, free), `fanboy-annoyances` (annoyances, **premium**). No Regional entry exists yet. No premium list sits in Ads/Privacy. | Only Annoyances has content to downgrade today. Regional path must still be correct (empty composition) but is untestable against real data; use fixtures. |
| F3 | `UpdatePlanner`, installed premium + not entitled | Premium check is evaluated **before** the `existing` lookup, so it returns `.skipPremium(entry)`. `UpdateCoordinator` ignores `.skipPremium`. Net: installed premium filter is silently kept. | `docs/gotchas.md` entitlement-gating entry is stale (says `.keep`/`.install`). Planner needs a new outcome: `.remove` (or `.revoke`) for installed+premium+not entitled. |
| F4 | `UpdateCoordinator` `.remove` | `runTransaction` **does** execute `.remove` via `pipeline.remove(...)` (TargetTopology.md L227 is stale on this). But removals are only produced for filters absent from the manifest, and `group` is derived from installed filters. | Reuse the existing removal path; add entitlement-driven removals. |
| F5 | Downgrade never runs when manifest unchanged | `manifestClient.fetch` returns `.notModified` → `run()` returns `.upToDate` before the plan is computed. | **Design-critical:** downgrade must be a separate entitlement reconcile step, not folded into the manifest fetch. Also required offline. |
| F6 | `pipeline.remove` semantics | Recomposes the group from remaining installed filters; an emptied group compiles `[]`, writes atomically, removes payload + `installed_filters.json` entry. Supports `.deferred` reload. | Right primitive. Needs a batch variant to remove N filters in one snapshot/rollback transaction. |
| F7 | DNS on entitlement loss | `DNSProtectionService.handleEntitlementLoss()` (stream observer + `loadStatus`) stops the tunnel, sets `manager.isEnabled=false`, saves, clears settings flag. **No on-demand code exists anywhere** (`isOnDemandEnabled` never referenced). Tunnel (`PacketTunnelProvider.startTunnel`) performs no entitlement check. No user-facing explanation. | Largely done. Add: explicit `isOnDemandEnabled=false` (defensive), user explanation, and tunnel-side backstop reading an App Group entitlement expiry. |
| F8 | `entitlement.json` content | `WebExtensionPersistedEntitlement(state: premiumActive|free, updatedAt)` — **boolean-equivalent, no expiry**. `background.js` gates on `entitlementState === "premiumActive"` + a 4 h grace ceiling on rules freshness; no `validUntil`. Coordinator only writes on capability *change* (dedupe). | Add `validUntil` to the shared type + publisher + bridge + JS compare. Dedupe must also republish when `validUntil` changes. |
| F9 | Entitlement signal | `EntitlementService.stateUpdates()` (AsyncStream) is the single signal; observers: `DNSProtectionService`, `WebExtensionEntitlementCoordinator`, `TrialExpiryRouter`, `TrialNotificationScheduler`, view models. Stream fires only on state *change*; `refreshEntitlements()` is invoked by listener/launch. **Nothing re-evaluates at the trial's expiry instant** — only on next refresh/foreground. `.annual(expiresAt:)` past-dated is still `hasPremiumAccess` until a refresh. | Add `EntitlementLossReconciler` subscribed to this stream **plus** launch/foreground/BG refresh calling `refreshEntitlements()` first. |
| F10 | Refund/revocation | `Transaction.currentEntitlements` excludes revoked/expired transactions, so refresh yields `.free`. No explicit `revocationDate` handling or test. | Covered by the same transition path; add tests proving revoked→`.free`→downgrade. |
| F11 | Notifications | Days 5/9/12/14/15 (copy below). Cancelled on any non-`.trial` state. Nothing is scheduled after day 15. | No change; listed for your trimming decision. |
| F12 | PRD file | PRD is at `docs/adblock-prd-v1.1.md` (not `docs/PRD/`); §9 already says 15 days. | Changelog line added 2026-10-29; file left at `docs/`. |

### Notification schedule (unchanged)
| Day | Title | Body |
|---|---|---|
| 5 | ADBLX Premium Trial | You have 10 days remaining in your 15-day free trial. |
| 9 | ADBLX Premium Trial | You have 6 days remaining in your 15-day free trial. |
| 12 | ADBLX Premium Trial | Your free trial ends in 3 days. |
| 14 | ADBLX Premium Trial | 1 day left in your free trial. |
| 15 | ADBLX Premium Trial | Your 15-day free trial ends today. |

Confirmed: nothing fires after day 15; all pending are cancelled on purchase / "Continue free".

## 3. Design

### 3.1 PlanState (FR-16)
`PlanState` (`premium(PremiumKind)`, `trial(daysRemaining, endsAt)`, `trialExpired(endedAt)`, `free`) with `isEntitled`, `isTrialEndingSoon (≤3)`.
- `PlanStateProvider` (actor) takes `now: @Sendable () -> Date`, `TrialSource` (protocol: `status(at:)`; `TrialManager` conforms via adapter) and a paid-entitlement source (`activePremiumKind()`), no singletons.
- Distinguishing `trialExpired` vs `free`: trial record exists and expired ⇒ `trialExpired`; no record ⇒ `free`. "Continue free" does **not** erase `trialExpired` (UI still says "Trial ended"); it only suppresses the full-screen.
- `PlanStateModel` (`@Observable @MainActor`) created in `AppCompositionRoot`, injected via environment; refreshes off-main on launch/foreground and on `stateUpdates()`. First frame renders `.free`-neutral placeholder; never awaited before first frame (NFR-05).
- Clock backwards: `TrialManager` already uses `max(date, lastObservedDate)`; add tests (provider must not regress to `.trial` from `.trialExpired`).

### 3.2 Downgrade (FR-17) — trigger on entitled→not-entitled
New `EntitlementLossReconciler` (actor). Inputs: `EntitlementService`, `UpdateCoordinator`-side `PremiumDowngrader`, `DNSProtectionService`, `WebExtensionEntitlementCoordinator`, iCloud coordinator (already self-gating), injected clock. Trigger: transition observed via `stateUpdates()` **and** a reconcile on launch/foreground/BG refresh (after `refreshEntitlements()`), compared with a persisted `lastReconciledEntitled` flag (App Group defaults) so a missed transition (app not running at expiry) still downgrades on next run. Idempotent: reconciling while already downgraded is a no-op.

Steps on loss:
1. **Content blockers** — `PremiumDowngrader`: read `installed_filters.json`; for every installed filter whose manifest entry is premium, remove it in **one** `FilterStore` snapshot/rollback transaction; recompose each affected group from remaining non-premium sources (empty → `[]`); atomic write; single deferred reload of affected extensions; per-extension reload errors surfaced (FR-06); `installed_filters.json` entries removed. Premium-ness source: the cached manifest (`ManifestStore`) — if none cached, fall back to a static set of premium groups (`annoyances`, `regional`) so offline/first-run still works.
2. **Planner** — when not entitled, installed premium ⇒ `.revoke(filterID)`; never `.install`/download for premium. Update gotcha + tests.
3. **No downloads** — `UpdateCoordinator` already skips premium when not entitled (F3); add test asserting zero download calls for premium entries and that downgrade runs even when manifest is `.notModified` (F5).
4. **Re-upgrade** — on gain, clear `lastReconciledEntitled`, invalidate cached ETag (`manifestStore` save with nil etag) and run `UpdateCoordinator.run()`, so premium lists reinstall via the normal path; web extension republishes.
5. **DNS** — keep `handleEntitlementLoss`; add `isOnDemandEnabled=false` + save, a persisted `dnsDowngradeNotice` flag shown by DNSProtection/Home, and tunnel backstop: app publishes `entitlement.json.validUntil` (shared file) and `PacketTunnelProvider.startTunnel` fails fast with a clear `NEVPN`-style error if `now > validUntil`. Single date comparison.
6. **Web extension** — `WebExtensionPersistedEntitlement` gains `validUntil: TimeInterval?` (nil for lifetime = no expiry; trial = `endsAt`; sub = `expiresAt`). Bridge returns it; `background.js` treats `now ≥ validUntil` as `free` (compared to wall clock on each evaluate; clock-backwards handled by existing wall/monotonic logic — verify). Fail-closed.
7. **iCloud** — already `guard isPremiumEntitled`; add test that allowlist/settings are untouched (never deleted).
8. **Bundle fix (F1)** — `installBundledSnapshotIfNeeded` installs Ads + Privacy only; bootstrap never installs/restores Annoyances. Entitled users receive Annoyances through the normal update path. Add a regression test that bundled install writes no annoyances/regional file. Existing installs with an unentitled Annoyances are cleaned up by the reconciler on first run.

### 3.3 Known limitation (accepted)
Content-blocker JSON is static: Annoyances/Regional keep blocking from the instant of expiry until the next launch/foreground/BG refresh. Web extension and tunnel enforce `validUntil` themselves and are exact.

### 3.4 UI (Phase 4 — Home card only after FR-17 merged)
As specified in your prompt: Settings "Plan" row, Premium header + Restore, Home chip (>3 d) / card (≤3 d) / "Your protection" card, dismissal rules (7 days, max 3), locked-feature → paywall focus, Continue-free equal prominence. "Still on" and "Turned off" lists are derived from `PlanState` + per-extension reload status, not hardcoded. Prices via StoreKit `displayPrice`. Dismissal state: App Group/UserDefaults, per-viewer convenience (count + last shown date).

## 4. Logging (docs/Architecture/Logging.md)
Enum case names, counts, durations only: `plan.stateChanged to=<case>`, `downgrade.groupsAffected=<n>`, `downgrade.reloadFailures=<n>`. No dates tied to identity, no URLs/rules.

## 5. Open questions (need your answer before Phase 2)
1. **Manifest as premium source (3.2.1):** OK to treat "premium" as manifest entry flag with a static group fallback, rather than persisting a `premium` bool on `InstalledFilter` (schema change to `installed_filters.json`)? I recommend adding the bool (decode-default `false`) — simpler and offline-safe. Which do you prefer?
2. **Grace on subscription lapse:** `transaction.expirationDate` passes → Apple's billing-retry/grace is *not* in `currentEntitlements`. Downgrade immediately when StoreKit says not entitled (my default), or honour a grace window? (Gotchas flagged this as needing product input.)
3. **Family Sharing / refunds:** assume StoreKit's `currentEntitlements` is authoritative. OK?
4. **`validUntil` for monthly/annual** = Apple `expirationDate`; add small fixed slack (e.g. 24 h) so web extension/tunnel don't cut off a renewing user before the app refreshes? My default: 24 h slack, none for trial.
5. **Where does Regional come from?** No manifest entry exists. Treat as out of scope beyond fixtures/group handling?
6. ~~PRD file~~ — resolved: changelog line added at `docs/adblock-prd-v1.1.md`.
7. **Notifications:** you decide on trimming; no change here.
8. **Stale docs:** I'll fix `gotchas.md` (entitlement gating) and `TargetTopology.md` L227 (`.remove` is executed) as part of the work — confirm.

## 6. Decisions (2026-10-29, supersede §3.2 / §5 where they differ)

1. **Persisted `InstalledFilter.premium: Bool?`.** `nil` = legacy record; resolved from the cached manifest, then `BundledPremiumCatalog` (there is no bundled *manifest* file in the app, so the catalog of bundled premium IDs plays that role), then persisted. The update path writes the flag from `FilterManifest.Entry.premium` on install/update.
2. **Immediate downgrade; no custom grace.** Lapse leniency is an App Store Connect setting (Billing Grace Period). **Unverified:** whether `Transaction.currentEntitlements` still returns a subscription during Billing Grace Period vs Billing Retry. Secondary sources agree grace keeps access and disagree on retry; Apple's docs were not confirmed. Verify with Xcode's StoreKit configuration "Billing Grace Period" simulation and `Product.SubscriptionInfo.RenewalState` (`.inGracePeriod`, `.inBillingRetryPeriod`) before relying on either behavior. Because the reconciler trusts `EntitlementService`, whatever StoreKit reports is what is enforced.
3. **`currentEntitlements` is authoritative.** `Transaction.updates` is already observed by `StoreKitSubscriptionService`, which feeds `stateUpdates()`; `PremiumEntitlementReconciler.startObserving()` subscribes, so a refund while the app is open downgrades immediately. Family Sharing is an App Store Connect product decision, not blocking.
4. **`validUntil`:** lifetime → none; subscription → StoreKit `expirationDate` + 7 days; trial → exact end. The app enforces the exact cutoff via reconcile. The tunnel start check and web extension use the same `validUntil`.
5. **Regional** out of scope beyond fixtures; the reconciler is group-generic (tests use Annoyances and Regional).
6. **Stale docs fixed** with the code that closed the gaps (`gotchas.md`, `TargetTopology.md`).

### Design changes
- **Level-triggered reconcile**, not edge-triggered; no "last reconciled" flag. Not entitled + premium installed → remove (one snapshot/rollback transaction across all affected groups). Entitled + default premium missing → install from bundle, and clear the cached manifest ETag so the next update does a full fetch (a 304 would otherwise never install it). Triggers: launch, scene-active (foreground), entitlement change, and before `UpdateCoordinator.run()`. Not entitled with no premium installed costs one metadata read and no reload; entitled costs two small metadata reads (installed filters + cached manifest) and no reload. There is no `BGAppRefreshTask` in the app today, so there is no background trigger yet.
- **`UpdatePlanner` unchanged:** `.skipPremium` already prevents premium downloads; removal belongs to the reconciler, so the planned `.revoke` action was dropped.
- **Bundle:** fanboy-annoyances stays bundled but `installBundledSnapshotIfNeeded(includePremium:)` installs it only for entitled users (`includePremium` defaults to false).
- **No `isOnDemandEnabled` code** (nothing uses on-demand). Added: tunnel start-time `validUntil` guard (`TunnelEntitlementGuard`) and an in-app "DNS Protection is paused" notice.
- **`FilterTransactionGate`:** reconciler and `UpdateCoordinator` transactions share the single `Previous/` rollback directory, so they are serialized.
