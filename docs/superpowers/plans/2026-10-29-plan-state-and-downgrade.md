# Plan State + Premium Downgrade Implementation Plan

> **Revised 2026-10-29 after spec decisions (§6).** Phase 2 as built: shared `validUntil` (T6) → `InstalledFilter.premium` + bundle gating (T1/T3) → level-triggered `PremiumEntitlementReconciler` + `FilterTransactionGate` (T4/T5/T8) → tunnel guard + DNS notice (T7) → docs (T9). T2 (`.revoke` planner action) was dropped: the reconciler owns removal. Status of each task is in the Phase 2 report.

Spec: `docs/superpowers/specs/2026-10-29-plan-state-and-downgrade-design.md`.
**Blocked on spec open questions (§5).** Every task is TDD (red → green → commit),
ends in a compiling, green tree (see gotchas: no "expected BUILD FAILED" boundaries),
injects a clock, and ends with `xcodebuild test` on a named simulator UDID.
After any `project.yml` change: `xcodegen generate` and commit the regenerated project.
Before changing `FilterPipeline.init`: `grep -rn "FilterPipeline(" ADBLX/ ADBLXTests/`.

## Phase 2 — FR-17 (release blocker for 8.1)

**T1 Bundle is free-only.** Test: after `installBundledSnapshotIfNeeded()` on a temp store, only Ads/Privacy compiled files exist, no `fanboy-annoyances` in `installed_filters.json`. Change: drop the annoyances block (+ resource stays for tests only / remove from target). Assertion style: pairwise per-group (gotcha: no set-equality).

**T2 Planner revokes.** Tests: installed premium + not entitled ⇒ `.revoke(id)`; + entitled ⇒ `.keep`; new premium + not entitled ⇒ `.skipPremium`; version bump while not entitled ⇒ `.revoke` not `.install`. Add `UpdateAction.revoke`; fix coordinator `switch` exhaustiveness.

**T3 `InstalledFilter.premium` (decode-default false)** — per open question 1. Tests: old JSON decodes; pipeline install records flag from manifest entry. Update the call-site grep list.

**T4 `PremiumDowngrader`.** Tests (fakes + temp store): (a) 2 premium filters in 2 groups removed in one transaction, groups compile `[]`, free groups' rule counts unchanged; (b) **partial failure mid-batch** (group 2 of 2 fails) ⇒ full rollback, both premium filters still installed (gotcha: batch needs partial-failure case); (c) per-extension reload error surfaced in result; (d) allowlist file byte-identical; (e) idempotent second call no-op. Add `FilterPipeline.removeBatch(...)` reusing `installGroup`.

**T5 Coordinator integration.** Tests: `.notModified` manifest + not entitled ⇒ downgrade still runs (F5); zero premium downloads when not entitled; re-entitle ⇒ ETag invalidated and premium reinstalled via normal path. Implement `UpdateCoordinator.reconcileEntitlement()` separate from `run()`.

**T6 `validUntil` end-to-end.** Shared type + publisher + bridge + `background.js` (single compare; JS tests incl. clock-backwards and lifetime/nil). Coordinator dedupe republishes on `validUntil` change. Slack per open question 4. Node suite + Swift tests green.

**T7 DNS.** Tests: loss ⇒ tunnel stopped, `isOnDemandEnabled == false` saved, settings disabled, persisted notice set, stays off after relaunch (fresh service instance); `PacketTunnelProvider` start-guard logic extracted into a pure `TunnelEntitlementGuard(now:validUntil:)` unit-tested (refuses after `validUntil`). Wire guard in `startTunnel`; reads App Group file only.

**T8 `EntitlementLossReconciler`.** Tests with injected clock + fake `EntitlementService`: trial expiry, subscription lapse, refund/revocation (each its own test), missed-transition-while-app-closed (persisted `lastReconciledEntitled`), launch/foreground triggers `refreshEntitlements()` first. Wire in `AppCompositionRoot`/`ADBLXApp` off-main, after first frame.

**T9 Docs.** Fix `gotchas.md` entitlement-gating entry (status: closed, planner behavior), `TargetTopology.md` L227, add ManualVerification section (expire trial → cookie-banner page shows banner, YouTube pre-roll returns, free ads page still blocked; purchase → all blocked again). **Phase 2 gate:** full `ADBLXTests` + `swift test` (ADBLXShared) + node suite green.

## Phase 3 — FR-16 (parallel with Phase 2; touches different files)

**T10 `PlanState` + `PlanStateProvider` + `TrialSource`.** Tests: every case; boundary days 4/3/2/0; expired vs never-started; clock-backwards never regresses `trialExpired`→`trial`; revoked sub with live trial ⇒ `trial`.
**T11 `PlanStateModel` (@Observable)**, composition-root-owned, injected via environment; refresh off-main; test refresh on `stateUpdates()` and foreground; cold-start check that nothing awaits it before first frame.

## Phase 4 — UI (starts after Phase 2 merged)

**T12 Settings Plan row** → Premium. **T13 Premium header + Restore Purchases.** **T14 Home chip/card + "Your protection" card** (inputs: `PlanState`, per-extension reload status, StoreKit `displayPrice`), dismissal store (7 d / max 3) with injected clock. **T15 Locked-feature → paywall focus.** **T16 Expired screen: equal-prominence "Continue free".** Strings in `Localizable.xcstrings` (no `try?`-swallowed lookups), VoiceOver labels, Dynamic Type snapshot checks. Each task keeps the tree compiling (add additive view first, wire call site in same task).

## Reporting
After each phase: changes, test output, contradictions with the prompt, deferrals.
Known contradictions already found: PRD file absent (PD-01 supersedes); `isOnDemandEnabled` unused today; `.remove` already executed; bundle ships premium Annoyances.
