# Sprint 9 — Task 3: YouTube Detection-State Model

**Status:** Complete / Ready for Validation  
**Date:** 2026-08-25  
**Governing Documents:** [Task 1 Contract](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_guarantees_and_non_guarantees.md), [Task 2A Validation Report](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_signal_runtime_validation.md), [ADR-0010](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0010-safari-web-extension-execution-and-update-model.md), [ADR-0013](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0013-layer-3-capability-boundary-and-explicit-non-goals.md)

---

## 1. Scope & Design Objective

Task 3 defines a **deterministic, bounded finite state machine (FSM)** for YouTube video ad state detection on iOS/iPadOS Safari.

The state machine:
* Uses **only** Task 2A-admitted signals (`SIG-01`, `SIG-02`, `SIG-03`, `SIG-05`, `SIG-06`, `SIG-07`).
* Operates strictly in the Content Script isolated world.
* Contains **zero intervention logic** (intervention actions are strictly decoupled and deferred to Task 4).
* Guarantees that any ambiguity or unexpected DOM structure fails closed into a safe, non-intervening state.

---

## 2. Invariants of the State Model

### Invariant 1 (Cardinal Playback Rule & Confirmation Authority)
> **Confirmation Authority Rules:**
> 1. **`SIG-02` (Validated Skip Control)** is independently sufficient to authorize entry into `AD_CONFIRMED` because Task 2A validated it as exclusive to ad intervals.
> 2. **`SIG-01` (Player Ad Class)** requires the `mediaActive` predicate or an allowed corroborating signal (`SIG-03` or `SIG-02`) to enter `AD_CONFIRMED`.
> 3. **`SIG-03` (Text/Badge)** is strictly corroborating and can **never** independently authorize entry into `AD_CONFIRMED`.
> 4. **`SIG-05` (Media Events)** serve exclusively as re-evaluation triggers, not persistent state classifiers.
> 5. **`SIG-06` (Media Properties)** serve as secondary validation predicates, not standalone detectors.

### Invariant 2 (Failure to Safety)
> **Any signal ambiguity, conflicting structural state, detached player container, or caught evaluation exception forces an immediate transition to `AMBIGUOUS_SAFE` or `UNKNOWN`. Under no circumstance will the machine guess or persist an intervention state without active structural evidence.**

### Invariant 3 (Decoupled Intervention Authority)
> **The detection engine outputs only the current state enum. Only the explicit `AD_CONFIRMED` state authorizes downstream intervention.** All other states (`UNKNOWN`, `NORMAL_PLAYBACK`, `AD_CANDIDATE`, `RESET_SETTLING`, `AMBIGUOUS_SAFE`) strictly prohibit intervention.

### Invariant 4 (SPA Monotonic Generation Discipline)
> **No callback associated with a previous player generation may mutate the FSM after a new navigation generation has begun.** A monotonic integer (`playerGeneration`) invalidates stale asynchronous callbacks across YouTube SPA video transitions.

---

## 3. State Inventory

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                                STATE INVENTORY                          │
├──────────────────────┬─────────────────────────────┬────────────────────┤
│ State Enum           │ Semantic Meaning            │ Intervention Auth? │
├──────────────────────┼─────────────────────────────┼────────────────────┤
│ 1. UNKNOWN           │ Page loaded / Player unset  │ NO (Prohibited)    │
│ 2. NORMAL_PLAYBACK   │ Legitimate video playback   │ NO (Prohibited)    │
│ 3. AD_CANDIDATE      │ Primary signal evaluating   │ NO (Evaluation)    │
│ 4. AD_CONFIRMED      │ Validated ad interstitial   │ YES (Authorized)   │
│ 5. RESET_SETTLING    │ Ad ended, restoring normal  │ NO (Teardown)      │
│ 6. AMBIGUOUS_SAFE    │ Signal conflict / fail-safe │ NO (Fail-Safe)     │
└──────────────────────┴─────────────────────────────┴────────────────────┘
```

### Detailed State Semantics

1. **`UNKNOWN`:**
   * Initial state on script injection or SPA navigation.
   * Player container element (`#movie_player`, `.html5-video-player`, `#player-container-id`) is not yet resolved.
   * Observer is detached or seeking the current player generation mount point.

2. **`NORMAL_PLAYBACK`:**
   * Player container is attached and `<video>` element is active.
   * Zero primary structural ad markers present ($\neg\text{SIG-01} \land \neg\text{SIG-02}$).
   * Normal video content is streaming or paused by user.

3. **`AD_CANDIDATE`:**
   * A primary structural signal has appeared ($\text{SIG-01}$ class added OR $\text{SIG-02}$ skip element mounted).
   * Acts as a transient filter to evaluate corroborating predicates and prevent single-frame race conditions during DOM re-rendering.

4. **`AD_CONFIRMED`:**
   * High-confidence ad break actively displaying.
   * **The only state that downstream Task 4 mechanisms are permitted to act upon.**

5. **`RESET_SETTLING`:**
   * Primary structural signals have cleared ($\neg\text{SIG-01} \land \neg\text{SIG-02}$).
   * Single-frame teardown state to ensure DOM mutations settle before returning to `NORMAL_PLAYBACK`.

6. **`AMBIGUOUS_SAFE`:**
   * Structural contradiction detected or caught evaluation error occurred.
   * Completely disables mitigation and yields control to native playback.

---

## 4. Evaluation Predicates & Transition Model

### 4.1 Fixed-Logic Helper Predicates

```text
mediaActive(video) :=
    video != null &&
    !video.paused &&
    !video.ended &&
    video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA

structuralAdPresent(player, controls) :=
    SIG-01(player.classList) || SIG-02(controls.skipButton)
```

### 4.2 State Transition Diagram

```text
                     ┌──────────────────┐
                     │     UNKNOWN      │
                     └────────┬─────────┘
                              │ P1: Player & media resolved
                              ▼
                     ┌──────────────────┐
          ┌─────────▶│ NORMAL_PLAYBACK  │◀──────────────────┐
          │          └────────┬─────────┘                   │
          │                   │ P2: SIG-01 OR SIG-02        │
          │                   ▼                             │
          │          ┌──────────────────┐                   │
          │          │   AD_CANDIDATE   │                   │
          │          └────┬────────┬────┘                   │
          │ P5: Clear     │        │ P3: Confirmation met   │ P6: Settle
          │ or timeout    │        ▼                        │ complete
          │          ┌────┴─────────────┐                   │
          │          │   AD_CONFIRMED   │                   │
          │          └────────┬─────────┘                   │
          │                   │ P4: Primary signals clear   │
          │                   ▼                             │
          │          ┌──────────────────┐                   │
          └──────────│  RESET_SETTLING  │───────────────────┘
                     └──────────────────┘
                              ▲
                              │ [Contradiction / Caught Exception]
                     ┌────────┴─────────┐
                     │  AMBIGUOUS_SAFE  │
                     └──────────────────┘
                              │ P8: Recovery (Primary clean + valid container)
                              └─────────────────────────────▶ [NORMAL_PLAYBACK]
```

---

## 5. Transition Predicate Table

| Transition ID | From State | To State | Exact Predicate Trigger |
| :--- | :--- | :--- | :--- |
| **P1: Init** | `UNKNOWN` | `NORMAL_PLAYBACK` | Player DOM node resolved $\land$ `<video>` resolved $\land \neg\text{SIG-01} \land \neg\text{SIG-02}$. |
| **P2: Candidate**| `NORMAL_PLAYBACK` | `AD_CANDIDATE` | $(\text{SIG-01 is TRUE}) \lor (\text{SIG-02 is TRUE})$. |
| **P3: Confirm** | `AD_CANDIDATE` | `AD_CONFIRMED` | $[\text{SIG-02 is TRUE}] \lor [\text{SIG-01} \land (\text{mediaActive} \lor \text{SIG-03})]$. |
| **P4: End** | `AD_CONFIRMED` | `RESET_SETTLING` | $\neg\text{SIG-01} \land \neg\text{SIG-02}$ (Ad class removed $\land$ skip button absent). |
| **P5: Abort** | `AD_CANDIDATE` | `NORMAL_PLAYBACK` | Predicate P3 not satisfied within `candidateConfirmationWindow` OR $\neg\text{structuralAdPresent}$. |
| **P6: Settle** | `RESET_SETTLING` | `NORMAL_PLAYBACK` | Next animation frame (`requestAnimationFrame`) $\land \neg\text{SIG-01} \land \neg\text{SIG-02}$. |
| **P7: Fail-Safe**| *ANY* | `AMBIGUOUS_SAFE` | Contradictory signals detected OR caught observer callback exception. |
| **P8: Recover** | `AMBIGUOUS_SAFE` | `NORMAL_PLAYBACK` | $\neg\text{SIG-01} \land \neg\text{SIG-02} \land \text{playerValid}$ held for `safeRecoveryStabilityWindow`. |

### Named Timing & Synchronization Parameters

* **`candidateConfirmationWindow`:** Bounded window (initial value: $100\text{ ms}$; evaluated in Task 6/7) for corroboration before falling back to `NORMAL_PLAYBACK`.
* **`safeRecoveryStabilityWindow`:** Bounded stability duration (initial value: $500\text{ ms}$; evaluated in Task 6/7) before exiting `AMBIGUOUS_SAFE`.
* **`next animation frame`:** Synchronized via `requestAnimationFrame`, eliminating fixed millisecond assumptions for UI settling.

---

## 6. Lifecycle, Error Handling, and SPA Robustness

### 6.1 Bounded Exception Handling in Observers
Observer callbacks must never allow uncaught exceptions to bubble or leave state undefined:

```javascript
function onPlayerMutation(mutations, generation) {
    if (generation !== currentGeneration) return;
    try {
        evaluateFSM();
    } catch (err) {
        logDiagnostic("FSM evaluation error", err);
        transitionTo(State.AMBIGUOUS_SAFE);
    }
}
```

### 6.2 SPA Navigation & Monotonic Generation Invariant
To prevent cross-navigation callback races on YouTube client-side transitions:
1. When navigation starts (`yt-navigate-start`, URL change, or video ID change):
   $$\text{playerGeneration} \leftarrow \text{playerGeneration} + 1$$
2. Existing `MutationObserver` instances are disconnected immediately.
3. Any in-flight callbacks or asynchronous timers check `if (callbackGeneration !== currentGeneration) return;` and discard execution.
4. FSM resets to `UNKNOWN` and initiates discovery for the new video player instance.

### 6.3 Decoupled `AMBIGUOUS_SAFE` Recovery
* `SIG-03` (text/badge) is explicitly excluded from blocking recovery.
* Recovery requires only that primary structural signals are clean ($\neg\text{SIG-01} \land \neg\text{SIG-02}$), the player container is structurally valid, and no contradiction is detected during `safeRecoveryStabilityWindow`.

---

## 7. Next Steps

With the detection state machine and invariants strictly amended and verified:
* **Task 3 Status:** **Complete / Ready for Validation**
* **Next Task:** **Task 4 — Candidate Interventions** (Evaluating candidate actions against the `AD_CONFIRMED` state).
