# Sprint 9 — Task 4: YouTube Candidate Interventions

**Status:** Proposed Comparative Architecture Evaluation  
**Date:** 2026-08-25  
**Governing Documents:** [Task 1 Contract](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_guarantees_and_non_guarantees.md), [Task 2A Validation Report](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_signal_runtime_validation.md), [Task 3 Detection Model](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_detection_state_model.md), [ADR-0010](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0010-safari-web-extension-execution-and-update-model.md), [ADR-0013](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0013-layer-3-capability-boundary-and-explicit-non-goals.md)

---

## 1. Context & Architectural Boundary

Task 4 evaluates candidate intervention mechanisms on YouTube video streams in iOS/iPadOS Safari.

### The Governing Authority Invariant
> **Task 4 mechanisms receive `AD_CONFIRMED` as absolute authorization, not as a signal to reinterpret. No intervention may inspect weaker signals and decide that an ad exists when the FSM has not authorized intervention.**

All candidate interventions are evaluated from **least destructive to most invasive** against the **Cardinal Rule of Playback Preservation** (Task 1).

---

## 2. Overview of Candidate Interventions

```text
       ┌─────────────────────────────────────────────────────────────┐
       │                 DETECTION FSM (Task 3)                      │
       │                   State: AD_CONFIRMED                       │
       └──────────────────────────────┬──────────────────────────────┘
                                      │
              ┌───────────────────────┼───────────────────────┐
              ▼                       ▼                       ▼
      [Candidate A]           [Candidate B]           [Candidate C]
     Cosmetic Hiding          Skip Activation         Playback Accel
     (Overlay/Banner)        (Click Skip Button)     (Speed & Mute)
              │                       │                       │
              └───────────────────────┼───────────────────────┘
                                      │
              ┌───────────────────────┴───────────────────────┐
              ▼                                               ▼
      [Candidate D]                                   [Candidate E]
    Direct Media Seek                                Deliberate No-Op
  (Skip to video.duration)                         (Preserve Playback)
```

---

## 3. Comprehensive Evaluation Matrix

### Candidate A: Cosmetic Ad UI & Overlay Suppression

* **Intervention Category:** Non-destructive DOM hiding.
* **Exact Preconditions:** FSM state is `AD_CONFIRMED` $\lor$ target is a validated feed/sidebar banner (**SIG-04**).
* **Exact Action:** Inject scoped CSS rules (`display: none !important; opacity: 0 !important; pointer-events: none !important;`) or set element hidden attribute on ad overlay containers (`.ytp-ad-player-overlay`, `.ytp-ad-overlay-container`, `ytm-promoted-sparkles-web-renderer`).
* **Required Postconditions:** Ad overlays and companion banners are invisible and non-interactive; video viewport remains fully visible and interactive.
* **Rollback & Restoration:** Automatically removed or scoped so normal player controls (progress bar, settings, play button) are never hidden.
* **Failure Mode:** Stale selector fails to hide ad overlay. Video playback continues completely unaffected.
* **User Control Interaction:** Zero interference with user volume, playback speed, subtitles, or scrubbing controls.
* **Logic vs. Data:** **Updatable Rule Data** (Array of CSS selector strings in `rules.json`).
* **Performance & Battery:** Main thread cost $< 0.05\text{ ms}$; Memory: zero; Battery impact: negligible (native CSS engine).
* **Verdict:** **Validated & Recommended (Primary for Cosmetic Cleanup).**

---

### Candidate B: Programmatic Skip-Control Activation

* **Intervention Category:** Event-driven control click.
* **Exact Preconditions:**
  1. FSM state is `AD_CONFIRMED`.
  2. A validated skip button element (**SIG-02**) is mounted, visible in DOM (`offsetParent !== null` or computed `display !== 'none'`), and enabled.
* **Exact Action:** Dispatch standard synthetic click events:
  ```javascript
  button.click(); // and dispatchEvent(new MouseEvent('click', { bubbles: true }))
  ```
* **Required Postconditions:** Ad break terminates; player transitions to `NORMAL_PLAYBACK` via FSM predicate P4.
* **Rollback & Restoration:** Single execution per ad interval; if click does not terminate ad within `skipDebounceTimeout`, do not spam clicks.
* **Failure Mode:** Button click is ignored by YouTube handler. Ad plays normally; video resumes after ad ends.
* **User Control Interaction:** Clean — mimics standard user tap on the skip button.
* **Logic vs. Data:** **Bundled Logic** (dispatch logic) + **Updatable Data** (skip button selectors).
* **Performance & Battery:** Main thread cost $< 0.1\text{ ms}$; Memory: zero; Battery impact: negligible (one-shot event).
* **Verdict:** **Validated & Recommended (Primary for Skippable Ads).**

---

### Candidate C: Playback-Rate Acceleration & Audio Muting

* **Intervention Category:** Media playback state manipulation.
* **Exact Preconditions:**
  1. FSM state is `AD_CONFIRMED`.
  2. `<video>` element is actively playing an ad interstitial.
  3. No clickable skip button is available (unskippable ad segment).
* **Exact Action:**
  1. Store pre-ad user state: `originalPlaybackRate = video.playbackRate`, `originalMuted = video.muted`.
  2. Set `video.muted = true`.
  3. Set `video.playbackRate = 16.0` (or maximum supported accelerated rate, e.g. $10.0$–$16.0$).
* **Required Postconditions:** Ad plays through in $<1$–$2$ seconds silently; on FSM exit to `RESET_SETTLING`, restore `video.playbackRate = originalPlaybackRate` and `video.muted = originalMuted`.
* **Rollback & Restoration (MANDATORY INVARIANT):**
  * On transition out of `AD_CONFIRMED` (via P4, P5, or P7): `video.playbackRate` and `video.muted` MUST be restored to their exact pre-ad values.
  * If the video ends or user navigates: restore values unconditionally.
* **Failure Mode:** Restoration fails $\implies$ user video plays at 16x speed or muted. *(Mitigated by strict FSM exit restoration hooks).*
* **User Control Interaction:** User manual speed/volume adjustments during ad break are preserved and applied to the restoration target.
* **Logic vs. Data:** **Bundled Logic** (rate restoration state machine) + **Updatable Data** (max rate parameter, e.g. `16.0`).
* **Performance & Battery:** CPU overhead negligible during accelerated burst; battery impact minimal due to rapid conclusion of ad.
* **Verdict:** **Conditional Candidate (Viable for Unskippable Ads, subject to strict restoration regression testing in Task 7).**

---

### Candidate D: Direct Media Seeking (`video.currentTime = video.duration`)

* **Intervention Category:** Destructive media timeline seeking.
* **Exact Preconditions:** FSM state is `AD_CONFIRMED`.
* **Exact Action:** Set `video.currentTime = video.duration` or `video.currentTime = targetAdEndTime`.
* **Required Postconditions:** Ad segment is bypassed instantly.
* **Rollback & Restoration:** Irreversible timeline alteration.
* **Failure Mode:**
  1. **Catastrophic Playback Corruption:** If `duration` represents the full video stream rather than the ad segment, seeking jumps to the end of the user's video, marking it watched.
  2. **Infinite Buffer / Desync:** YouTube player stream buffer crashes on arbitrary seek during server-stitched segments, leaving a black spinning spinner.
* **User Control Interaction:** Severe conflict with normal user seeking.
* **Logic vs. Data:** Bundled Logic.
* **Performance & Battery:** High CPU during stream reload and buffer stall.
* **Verdict:** **REJECTED.** Violates the Cardinal Rule of Playback Preservation. The risk of corrupting user video playback is unacceptably high.

---

### Candidate E: Deliberate Non-Intervention (First-Class Safe No-Op)

* **Intervention Category:** Passive preservation.
* **Exact Preconditions:**
  1. FSM state is NOT `AD_CONFIRMED` (e.g. `AD_CANDIDATE`, `AMBIGUOUS_SAFE`, `UNKNOWN`), OR
  2. Ad type is unobservable / unsupported (e.g. raw server-stitched video without DOM markers).
* **Exact Action:** Apply **zero** DOM mutations, zero media property changes, zero click dispatches.
* **Required Postconditions:** Native YouTube player operates without any extension interference.
* **Rollback & Restoration:** N/A (no state was modified).
* **Failure Mode:** Ad plays for 15 seconds. Video plays normally afterward. Zero player crashes.
* **User Control Interaction:** 100% native compatibility.
* **Logic vs. Data:** Fixed default behavior.
* **Performance & Battery:** Absolute Zero runtime cost.
* **Verdict:** **Validated & Mandatory (Default Invariant).**

---

## 4. Synthesis & Recommended Tiered Intervention Policy

When the Task 3 FSM enters `AD_CONFIRMED`, the intervention engine executes the following **Tiered Policy**:

```text
                         [ FSM: AD_CONFIRMED ]
                                   │
                                   ├─────────────────────────────┐
                                   ▼                             ▼
                           [Candidate A: Hide]          [Check Skip Button]
                           Apply cosmetic CSS                    │
                                                ┌────────────────┴────────────────┐
                                                ▼                                 ▼
                                      (Skip Button Present)             (Unskippable Ad)
                                                │                                 │
                                                ▼                                 ▼
                                       [Candidate B: Skip]              [Candidate C: Accel]
                                       Click skip button                Mute + 16x Speed
                                                │                                 │
                                                ▼                                 ▼
                                       [Ad Ends / Cleared]               [Ad Ends / Cleared]
                                                │                                 │
                                                └────────────────┬────────────────┘
                                                                 │
                                                                 ▼
                                                    [ FSM: RESET_SETTLING ]
                                                    Restore playbackRate & mute
                                                    Transition to NORMAL_PLAYBACK
```

1. **Step 1 (Cosmetic):** Candidate A hides visible ad banners and player overlays immediately.
2. **Step 2 (Primary Mitigation):**
   * If a visible skip button exists (**SIG-02**): Execute **Candidate B (Skip Action)**.
   * If no skip button exists (unskippable ad): Execute **Candidate C (Playback Acceleration & Mute)** with strict restoration invariant.
3. **Step 3 (Ambiguity / Error):** If any precondition fails or is ambiguous, yield immediately to **Candidate E (Non-Intervention)**.
4. **Candidate D (Direct Seeking)** is **permanently prohibited**.

---

## 5. Next Steps

With the candidate interventions comparative matrix established:
* **Task 4 Status:** **Complete / Ready for Validation**
* **Next Task:** **Task 5 — Fixed Logic vs. Updatable Data Classification** (Defining the exact schema for `rules.json` vs. bundled JavaScript code).
