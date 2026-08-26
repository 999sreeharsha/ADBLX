# Sprint 9 — Task 6: YouTube Performance, Observer Lifecycle, and Battery Budget

**Status:** Complete / Budget Normalization Applied  
**Date:** 2026-08-25  
**Governing Documents:** [Task 1 Contract](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_guarantees_and_non_guarantees.md), [Task 2A Validation Report](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_signal_runtime_validation.md), [Task 3 Detection Model](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_detection_state_model.md), [Task 4 Interventions](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_candidate_interventions.md), [Task 5 Classification](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_logic_vs_data_classification.md)

---

## 1. Scope, Measurement Targets, and Baseline Context

This specification defines the **normalized performance, lifecycle, memory, and energy admission criteria** for the Layer 3 YouTube Web Extension engine on iOS/iPadOS Safari.

### Target Environment
* **Platform Scope:** iOS 17.5+ and iPadOS 17.5+ Safari
* **Target Surfaces:** `m.youtube.com` (mobile layout) and `www.youtube.com` (desktop/tablet layout)
* **Measurement Principle:** Explicitly separate **hard architectural invariants** (which are non-negotiable correctness rules) from **initial design targets** (which are calibrated and measured against empirical baselines during harness execution).

---

## 2. Architectural Invariants vs. Engineering Design Targets

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                       BUDGET CLASSIFICATION MODEL                       │
├─────────────────────────────────────┬───────────────────────────────────┤
│ Non-Negotiable Invariants           │ Initial Design Targets (Harness)  │
├─────────────────────────────────────┼───────────────────────────────────┤
│ • Synchronous main-thread < 16 ms   │ • Startup budget ~ 1.8–2.0 ms     │
│ • No intentional timers / polling   │ • Callback durations ~ 0.3–0.5 ms │
│ • Observer scoped strictly to player│ • Retained memory ~ 50 KB         │
│ • Stale playerGeneration discarded  │ • Peak transient memory ~ 80 KB   │
│ • Zero monotonic SPA memory growth  │ • Controlled energy delta vs base │
│ • Candidate B single-dispatch       │ • Acceleration exit duration      │
│ • Candidate C exact restoration     │                                   │
└─────────────────────────────────────┴───────────────────────────────────┘
```

---

## 3. Instrumentation & Diagnostic Signpost Plan

Profiling uses unified `os_signpost` telemetry (in Swift native bridge) and `performance.mark` / `performance.measure` (in JS Content Script), captured via **Instruments** (Time Profiler, Allocations, Energy Log).

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                      SIGNPOST INSTRUMENTATION PLAN                      │
├─────────────────────────┬───────────────────┬───────────────────────────┤
│ Category                │ Subsystem         │ Interval Signpost Name    │
├─────────────────────────┼───────────────────┼───────────────────────────┤
│ 1. Extension Lifecycle  │ com.ADBLX.ADBLX   │ ContentScriptInit         │
│ 2. Player Discovery     │ com.ADBLX.ADBLX   │ PlayerContainerResolution │
│ 3. Observer Lifecycle   │ com.ADBLX.ADBLX   │ ObserverAttach / Detach   │
│ 4. State Evaluation     │ com.ADBLX.ADBLX   │ FSMEvaluationPass         │
│ 5. Intervention Accel   │ com.ADBLX.ADBLX   │ AccelBurstAndRestore      │
│ 6. SPA Transition       │ com.ADBLX.ADBLX   │ SPAGenerationTeardown     │
└─────────────────────────┴───────────────────┴───────────────────────────┘
```

---

## 4. Content-Script Startup & Activation Budget

### Hard Architectural Guardrail:
* **Max Synchronous Main-Thread Execution:** $< 16.0\text{ ms}$ (Layer 3 must not independently consume more than one nominal 60 Hz frame budget in a synchronous activation path).

### Initial Design Targets:
* **Total Synchronous Startup:** Target $\le 2.0\text{ ms}$ total execution from script entry to initial observer attachment.

```text
[Content Script Injected]
         │
         ├── Async fetch cached generation from storage.local (Target: < 1.0 ms)
         ├── DOM Query for Player Container (#movie_player) (Target: < 0.5 ms)
         ├── Attach Scoped MutationObserver (Target: < 0.3 ms)
         └── Initial FSM Evaluation (UNKNOWN → NORMAL_PLAYBACK) (Target: < 0.3 ms)
```

| Metric | Initial Design Target | Hard Failure Guardrail | Measurement Method |
| :--- | :--- | :--- | :--- |
| **Script Parse & Initial Execution** | $\le 1.0\text{ ms}$ | $> 5.0\text{ ms}$ | `performance.now()` entry to ready |
| **Player Container Discovery** | $\le 0.5\text{ ms}$ | $> 3.0\text{ ms}$ | Scoped `querySelector` lookup |
| **Initial Observer Setup** | $\le 0.3\text{ ms}$ | $> 2.0\text{ ms}$ | `MutationObserver.observe()` |
| **Total Synchronous Startup** | $\mathbf{\le 2.0\text{ ms}}$ | $\mathbf{> 16.0\text{ ms}}$ | Main-thread synchronous time |

---

## 5. Steady-State Observer & Callback Discipline

The `MutationObserver` must attach strictly to the active player container (`#movie_player` or mobile container) with `attributeFilter: ['class']` and `childList: true`.

### Hard Invariants:
1. **No Intentional Polling:** Layer 3 must not perform periodic background checks or timer loops.
2. **Idle / Paused Tab Behavior:** Layer 3 must not perform periodic work while paused or idle. If the observer remains attached, callbacks caused by external page DOM mutations may occur, but they must perform bounded, constant-time state checks and must not trigger intervention unless the FSM is eligible.

| Operational Flow | Initial Callback Target | Initial Duration Target | Aggregate CPU Target |
| :--- | :--- | :--- | :--- |
| **Normal Long-Form Playback** | $\le 5\text{ callbacks/min}$ | $\le 0.3\text{ ms}$ | $\le 2.0\text{ ms/min}$ |
| **Shorts Playback** | $\le 10\text{ callbacks/min}$ | $\le 0.4\text{ ms}$ | $\le 5.0\text{ ms/min}$ |
| **Active Ad Interstitial (Ad)** | $\le 20\text{ callbacks/burst}$ | $\le 0.5\text{ ms}$ | $\le 10.0\text{ ms/burst}$ |
| **Idle / Paused Video Tab** | Zero periodic timers | $\le 0.1\text{ ms}$ if page mutates | $\le 0.5\text{ ms/min}$ |

---

## 6. Observer Lifecycle & SPA Navigation Leak Budget

On YouTube client-side SPA navigation:
1. `playerGeneration` is **synchronously incremented** before teardown and rebind work.
2. The previous observer is explicitly disconnected (`observer.disconnect()`).
3. Callbacks compare their captured generation against `playerGeneration` and discard execution if mismatched.

```text
[SPA Navigation Trigger]
         │
         ├── playerGeneration++ (Logical generation bump)
         ├── observer.disconnect() (Immediate detachment)
         ├── Invalidate and drop pending asynchronous callbacks
         └── Discover new player & bind fresh observer
```

### Hard Acceptance Gates:
* **No Stale Observer Retention:** No observer from a superseded `playerGeneration` may remain active after that generation's teardown completes. Temporary overlap during transition handoff is permissible.
* **No Monotonic Growth:** Total retained memory and DOM node references after repeated navigation cycles (10, 50, 100 transitions) must return to a statistically stable envelope after GC settling.

---

## 7. Intervention-Specific Performance & Safety Budgets

### Candidate A: Cosmetic Hiding
* **Action Latency:** Applied declaratively via CSS injection ($\sim 0\text{ ms}$ main thread).
* **Layout Thrashing Rule:** Zero forced synchronous reflows (no style/dimension queries following rule application).

### Candidate B: Skip Click Dispatch
* **Dispatch Invariant:** Single synthetic click dispatch per ad interval; repeated clicking during a single ad interval is prohibited.
* **FSM Settle Duration:** Transition from `AD_CONFIRMED` $\to$ `RESET_SETTLING` within next animation frame (`requestAnimationFrame`).

### Candidate C: Playback Acceleration & Safety Timeout
* **Mandatory Exact Restoration Invariant:**
  $$\text{RestoredRate} \equiv \text{OriginalRate} \quad \land \quad \text{RestoredMute} \equiv \text{OriginalMute}$$
  Tested across all completion, error, and navigation paths: **100% exact restoration required**.
* **Safety Intervention Timeout:** If accelerated ad playback does not conclude within a maximum timeout (`accelerationSafetyTimeoutMs`, default: $5000\text{ ms}$ real elapsed time), the engine MUST unconditionally restore original rate/mute and yield to `AMBIGUOUS_SAFE` (Candidate E non-intervention).

---

## 8. Memory Measurement Contract

Memory footprint is evaluated on physical devices using **Instruments (Allocations)**.

### Acceptance Criteria:
* **Zero Monotonic Leak:** Memory must stabilize without continuous upward drift across repeated SPA navigation cycles.
* **Initial Engineering Targets (Pending Baseline Calibration):**
  * Content script steady-state retained heap: Target $\le 50\text{ KB}$.
  * Transient peak during acceleration burst: Target $\le 80\text{ KB}$.
  * Upper regression ceiling: Target $\le 200\text{ KB}$.

---

## 9. Energy & Battery Comparison Methodology

Energy impact is evaluated using a **controlled A/B methodology** on physical iOS 17+ hardware:

### Controlled Test Protocol:
1. Identical physical device, battery state of charge ($>80\%$), thermal state, and display brightness.
2. Identical iOS build and Safari configuration.
3. Identical YouTube test flows (30-minute automated playlist playback).
4. $N \ge 5$ repeated test runs per condition; compare median and variance across:
   * **Condition A (Baseline):** Safari + Native YouTube.
   * **Condition B (Test):** Safari + YouTube + Layer 3 Enabled.

### Hard Energy Invariants:
1. **No Background Churn:** Zero intentional timers, polling, or active intervention work when the YouTube tab is hidden or backgrounded.
2. **Controlled Overhead:** Incremental CPU and energy impact must remain within a statistically stable variance envelope determined during baseline calibration.

---

## 10. Summary of Frozen Task 6 Gates

| Domain | Invariant / Acceptance Gate | Verification Tool |
| :--- | :--- | :--- |
| **Main-Thread Work** | Hard guardrail $< 16\text{ ms}$ (Target $\le 2\text{ ms}$) | Time Profiler / Signpost |
| **Observer Attachment** | Scoped strictly to active player; no unconstrained body observation | DOM Inspection |
| **Observer Lifecycle** | No stale observer survives generation teardown; stale callbacks discarded | Memory Profiler |
| **Idle Work** | Zero intentional polling/timers while paused or backgrounded | Energy Log |
| **SPA Memory Stability** | Zero monotonic heap leak across 50+ navigations | Allocations Trace |
| **Rate Restoration** | 100% exact restoration of user rate/mute on exit or safety timeout | Automated Unit/UI Test |
| **Energy Methodology** | Controlled A/B baseline comparison across $N \ge 5$ runs | Instruments Energy Log |

---

## 11. Next Steps

With Task 6 performance invariants and normalized budgets established:
* **Task 6 Status:** **Complete / Budget Normalization Applied**
* **Next Task:** **Task 7 — Failure Modes and Regression Matrix** (Defining comprehensive edge cases, failure recoveries, and regression test matrix across YouTube UI variations).
