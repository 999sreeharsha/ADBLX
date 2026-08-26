# Sprint 9 — Task 8: YouTube Mechanism Decision and Implementation Plan

**Status:** Final Mechanism Decision & Implementation Roadmap  
**Date:** 2026-08-25  
**Governing ADRs:** [ADR-0010](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0010-safari-web-extension-execution-and-update-model.md), [ADR-0011](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0011-web-extension-rule-data-generation-lifecycle-and-publication.md), [ADR-0012](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0012-native-js-bridge-transport-entitlement-refresh-points.md), [ADR-0013](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0013-layer-3-capability-boundary-and-explicit-non-goals.md)  
**Supporting Task Specs:** [Task 1 Contract](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_guarantees_and_non_guarantees.md), [Task 2A Validation](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_signal_runtime_validation.md), [Task 3 Detection Model](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_detection_state_model.md), [Task 4 Interventions](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_candidate_interventions.md), [Task 5 Classification](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_logic_vs_data_classification.md), [Task 6 Budget](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_performance_and_battery_budget.md), [Task 7 Regression Matrix](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_failure_modes_and_regression_matrix.md)

---

## 1. Final Mechanism Decision Statement

> **SHIELD Sprint 9 adopts a DOM-state-driven, event-triggered YouTube mitigation engine using validated structural signals, a fail-safe detection finite state machine (FSM), scoped player observation, cosmetic suppression, and synthetic skip activation. Playback acceleration (Candidate C) is retained as a compiled binary capability but initially disabled by default via remote data mask (`accelerationDisabled: true`) pending separate on-device empirical validation. Direct media seeking (Candidate D) is permanently out of scope.**

---

## 2. Complete Architecture Topology

```text
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                 APP CONTAINER (Main App)                                │
│  • Compiles generational rules.json off-main thread (ADR-0011)                           │
│  • Enforces schema validation, selector complexity caps, and parameter bounds           │
│  • Atomically publishes to App Group (AtomicRuleWriter + current.json swap)             │
│  • Maintains independent entitlement.json (Decoupled lifecycle)                         │
└────────────────────────────────────────────┬────────────────────────────────────────────┘
                                             │ App Group Container (Read-Only)
                                             ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                      SAFARI WEB EXTENSION NATIVE HANDLER (Swift)                        │
│  • SafariWebExtensionHandler.swift implements pull-only bridge (ADR-0012)               │
│  • Handles checkVersion (reads current.json + entitlement.json)                         │
│  • Handles fetchGeneration (reads active generation rules.json)                         │
│  • Independent status axes: generationStatus & entitlementState                         │
│  • Re-reads pointer and retries once on missing generation                              │
└────────────────────────────────────────────┬────────────────────────────────────────────┘
                                             │ Native Messaging Bridge (Pull-Only)
                                             ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                       BACKGROUND SCRIPT (background.js, MV3)                            │
│  • Event-page background context (scripts array, persistent: false) (ADR-0010)          │
│  • Wakes on browser events; refreshes state on wake (ADR-0012)                          │
│  • Maintains in-memory cache with 15-minute monotonic freshness ceiling                 │
│  • Uses browser.storage.local as warm cache across suspensions                          │
│  • Dispatches configuration to content scripts                                          │
└────────────────────────────────────────────┬────────────────────────────────────────────┘
                                             │ Asynchronous Extension Message Passing
                                             ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                       CONTENT SCRIPT RUNTIME (content.js, MV3)                          │
│                                                                                         │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │ 1. Hostname Gate & Discovery: Binary Allowlist (m.youtube.com, www.youtube.com)   │  │
│  │    • Resolves player container node (#movie_player, ytm-mobile-player)            │  │
│  │    • Increments playerGeneration on SPA navigation; unbinds stale observers       │  │
│  └─────────────────────────────────────────┬─────────────────────────────────────────┘  │
│                                            ▼                                            │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │ 2. Scoped Observer & Lifecycle Engine                                              │  │
│  │    • MutationObserver scoped strictly to player (attributeFilter: ['class'])      │  │
│  │    • Standard W3C HTMLMediaElement listeners (play, playing, ended, timeupdate)   │  │
│  │    • Cross-generation continuation guards (callbackGen === playerGeneration)     │  │
│  └─────────────────────────────────────────┬─────────────────────────────────────────┘  │
│                                            ▼                                            │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │ 3. Detection Finite State Machine (Task 3)                                        │  │
│  │    UNKNOWN ──▶ NORMAL_PLAYBACK ──▶ AD_CANDIDATE ──▶ AD_CONFIRMED ──▶ RESET        │  │
│  │                                      │                     │                      │  │
│  │                                      ▼ (Ambiguity)         ▼                      │  │
│  │                                 AMBIGUOUS_SAFE     Intervention Authorized        │  │
│  └─────────────────────────────────────────┬─────────────────────────────────────────┘  │
│                                            ▼                                            │
│  ┌───────────────────────────────────────────────────────────────────────────────────┐  │
│  │ 4. Tiered Intervention Dispatcher (Task 4 & 8)                                    │  │
│  │    • Step 1: Candidate A — Cosmetic suppression (hide banner & ad overlay)        │  │
│  │    • Step 2: Candidate B — Skip button synthetic click (if SIG-02 visible)        │  │
│  │    • Step 3: Candidate E — Non-intervention default (if unskippable ad)           │  │
│  │    • [Capability C]: Accel compiled, but accelerationDisabled: true in v1         │  │
│  └───────────────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Staged Implementation Plan (Phases 1–6)

### Phase 1: App Group Rule Publishing & Native Messaging Bridge

**Objectives:** Implement the native Swift data pipeline and `SafariWebExtensionHandler` conforming to ADR-0011 and ADR-0012.

* **Task 1.1: Shared Types & Paths in `ADBLXShared`:**
  * Create `WebExtensionAppGroupPaths.swift` (container URLs, generations dir, staging, current pointer, entitlement path).
  * Create `WebExtensionGenerationManifest.swift` and `WebExtensionCurrentPointer.swift`.
* **Task 1.2: Main App Rules Staging & Atomic Publisher:**
  * Create `WebExtensionRulePublisher.swift` in main app.
  * Implement schema validation: selector complexity caps ($\le 256\text{ chars}$, depth $\le 4$), numeric bounds checking ($1.0 \le \text{rate} \le 16.0$), binary domain allowlist enforcement.
  * Integrate atomic directory publishing and `current.json` pointer swap via `AtomicRuleWriter`.
* **Task 1.3: `SafariWebExtensionHandler.swift` Implementation:**
  * Replace the Sprint 0 echo handler with the structured two-message protocol:
    * `checkVersion`: Reads `current.json` and `entitlement.json` (returns `generation`, `generationStatus`, `entitlementState`, `checkedAt`).
    * `fetchGeneration`: Reads active `rules.json` with reread-pointer/retry-once on missing generation.
  * Enforce fail-closed entitlement vs. graceful rule data failure axes.

**Phase 1 Acceptance Gate:**
* Unit tests verify: 100% fail-closed on entitlement loss; retry-once on missing generation; zero main-thread file I/O; generation schema rejects out-of-bounds parameters.

---

### Phase 2: Web Extension Background Context & Caching

**Objectives:** Implement `background.js` event-page lifecycle, in-memory caching, and local storage persistence conforming to ADR-0010 and ADR-0012.

* **Task 2.1: Manifest V3 & Background Event Configuration:**
  * Update `manifest.json` to Manifest V3 with `background.scripts: ["background.js"]` (event-page form).
  * Declare narrow match patterns for YouTube domains (`*://*.youtube.com/*`).
* **Task 2.2: Background Cache & Freshness Engine in `background.js`:**
  * Implement wake-from-suspension handler that immediately issues `checkVersion`.
  * Implement 15-minute monotonic elapsed cache-age ceiling (`performance.now()`).
  * Implement `browser.storage.local` warm cache persistence across event-page suspensions.
  * Implement message router answering content-script state queries from memory.

**Phase 2 Acceptance Gate:**
* Automated bridge tests verify: Zero periodic timers/polling loops; `storage.sync` strictly absent; 15-minute cache expiry forces fresh `checkVersion`; rules JSON parsed once per generation.

---

### Phase 3: YouTube Content-Script Lifecycle & Scoped Observer

**Objectives:** Implement `content.js` lifecycle management, player container discovery, and `playerGeneration` cross-navigation race protection.

* **Task 3.1: Hostname Allowlist & Player Discovery:**
  * Hardcode binary hostname allowlist `["m.youtube.com", "www.youtube.com"]`. Abort if host is not matched.
  * Implement scoped player container discovery (`#movie_player`, `.html5-video-player`, `ytm-mobile-player`).
* **Task 3.2: Generation Tracking & Asynchronous Continuation Guards:**
  * Implement monotonic `playerGeneration` integer.
  * Implement SPA navigation hooks (`yt-navigate-start`, URL/history mutation) that increment `playerGeneration` and disconnect old observers.
  * Wrap all asynchronous callbacks (`MutationObserver`, `requestAnimationFrame`, `setTimeout`, native messages) with `if (capturedGen !== playerGeneration) return;`.
* **Task 3.3: Scoped `MutationObserver` & Media Event Attachment:**
  * Attach observer strictly to resolved player container node with `attributeFilter: ['class']` and `childList: true`.
  * Bind W3C media event listeners (`play`, `playing`, `ended`, `timeupdate`, `durationchange`) to `<video>`.

**Phase 3 Acceptance Gate:**
* Benchmark tests verify: Synchronous startup $\le 2.0\text{ ms}$ ($< 16\text{ ms}$ ceiling); zero observer retention after SPA navigation teardown; zero memory leaks across 50 navigations.

---

### Phase 4: YouTube Detection Finite State Machine (FSM)

**Objectives:** Implement the Task 3 deterministic 6-state detection engine in `content.js`.

* **Task 4.1: Helper Predicates & Signal Invariants:**
  * Implement `mediaActive` predicate (`!video.paused && !video.ended && video.readyState >= HAVE_CURRENT_DATA`).
  * Implement structural signal checkers (`SIG-01` player classes, `SIG-02` skip button presence, `SIG-03` corroborating badges).
* **Task 4.2: State Machine Implementation:**
  * Implement states: `UNKNOWN`, `NORMAL_PLAYBACK`, `AD_CANDIDATE`, `AD_CONFIRMED`, `RESET_SETTLING`, `AMBIGUOUS_SAFE`.
  * Enforce Invariant 1: Solo `SIG-03` never confirms ad state.
  * Enforce Invariant 2: Caught exceptions and structural contradictions transition immediately to `AMBIGUOUS_SAFE`.
  * Enforce Invariant 3: Only `AD_CONFIRMED` authorizes downstream intervention.

**Phase 4 Acceptance Gate:**
* FSM unit tests verify: 100% adherence to predicate transition table; solo text badge rejected; rapid signal flapping yields to safe state; zero false positives during normal video or Shorts.

---

### Phase 5: Tiered Intervention Dispatcher

**Objectives:** Implement the Task 4 / Task 8 tiered intervention engine.

* **Task 5.1: Cosmetic Suppression (Candidate A):**
  * Inject scoped cosmetic styles hiding companion/feed banners (`SIG-04`) and player ad overlays when `AD_CONFIRMED`.
* **Task 5.2: Programmatic Skip Button Activation (Candidate B):**
  * When `AD_CONFIRMED` $\land$ visible `SIG-02` skip button exists: dispatch debounced synthetic click event.
* **Task 5.3: Default Non-Intervention & Compiled Acceleration Safeguards:**
  * Implement default non-intervention (Candidate E) for unskippable ads.
  * Compile Candidate C (16x acceleration + mute + exact restoration machine + safety timeout) in code, but configure `accelerationDisabled: true` in default `rules.json` v1.0.

**Phase 5 Acceptance Gate:**
* Intervention tests verify: Skip button clicked within $\le 50\text{ ms}$; cosmetic overlays hidden cleanly; direct media seeking (Candidate D) strictly absent from codebase; non-intervention default preserves normal unskippable ad playback.

---

### Phase 6: Comprehensive Hardware Validation Gate

**Objectives:** Execute the Task 7 regression matrix and Task 6 performance verification across physical iOS/iPadOS hardware.

* **Task 6.1: Automated Test Matrix Execution:**
  * Run all 29 failure scenarios across Domain A (Lifecycle), Domain B (Detection), Domain C (Intervention), Domain D (Entitlement), and Domain E (Async Races).
* **Task 6.2: Physical Device Verification Matrix:**
  * iPhone 15/16 (iOS 17/18) and iPad Pro (iPadOS 17/18).
  * Surfaces: `m.youtube.com` and `www.youtube.com`.
  * Flows: Long-form, Shorts, skippable ads, unskippable ads, banners, SPA navigations, fullscreen/PiP.
* **Task 6.3: Memory & Energy A/B Profiling:**
  * Execute 50+ repeated SPA navigation leak test (Instruments Allocations).
  * Execute $N=5$ Energy Log benchmark runs comparing native Safari baseline vs. Layer 3 enabled.

**Phase 6 Acceptance Gate:**
* Verification report signed off: 100% of Task 7 test cases passing; zero monotonic memory leaks; zero frame drops $>16\text{ ms}$; incremental energy overhead within calibrated variance.

---

## 4. Summary of Closed Architecture Artifacts

| Document | Purpose & Scope | Status |
| :--- | :--- | :--- |
| [**ADR-0010**](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0010-safari-web-extension-execution-and-update-model.md) | MV3, `background.scripts`, bundled logic, strict App Store 2.5.2 boundary | **Proposed** |
| [**ADR-0011**](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0011-web-extension-rule-data-generation-lifecycle-and-publication.md) | Self-contained generation snapshots, decoupled `entitlement.json`, atomic swap | **Proposed** |
| [**ADR-0012**](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0012-native-js-bridge-transport-entitlement-refresh-points.md) | Pull-only two-message bridge, fail-closed auth vs 4h grace, 15m cache ceiling | **Proposed** |
| [**ADR-0013**](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0013-layer-3-capability-boundary-and-explicit-non-goals.md) | 3 admitted categories, 5-step admission test, explicit non-goals | **Proposed** |
| [**Task 1 Contract**](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_guarantees_and_non_guarantees.md) | Honest guarantees, explicit non-guarantees, Cardinal Rule of Playback | **Complete** |
| [**Task 2A Report**](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_signal_runtime_validation.md) | Empirical validation matrix for SIG-01 through SIG-08 | **Passed** |
| [**Task 3 Detection Model**](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_detection_state_model.md) | 6-state deterministic FSM, `mediaActive` predicate, transition table | **Complete** |
| [**Task 4 Interventions**](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_candidate_interventions.md) | Evaluation of Candidates A–E; seeking rejected, tiered policy defined | **Complete** |
| [**Task 5 Classification**](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_logic_vs_data_classification.md) | Logic vs data classification, `rules.json` v1.0 schema, disable mask | **Complete** |
| [**Task 6 Budget**](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_performance_and_battery_budget.md) | Normalized performance, observer lifecycle, SPA leak gates, energy A/B | **Complete** |
| [**Task 7 Regression Matrix**](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_failure_modes_and_regression_matrix.md) | 29 failure scenarios across 5 domains, async generation continuation guards | **Complete** |
| [**Task 8 Plan**](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_mechanism_decision_and_implementation_plan.md) | Final mechanism decision & 6-phase implementation roadmap | **Complete** |

---

## 5. Conclusion & Transition to Execution

The architectural design phase for Sprint 9 is **fully closed**. All technical, lifecycle, security, performance, and failure boundaries are documented and bounded.

We are ready to transition directly into **Sprint 9 Implementation Execution** beginning with **Phase 1: App Group Rule Publishing & Native Messaging Bridge**.
