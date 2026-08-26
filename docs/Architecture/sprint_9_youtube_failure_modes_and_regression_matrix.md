# Sprint 9 — Task 7: YouTube Failure Modes and Regression Matrix

**Status:** Proposed Architecture Specification & Regression Contract  
**Date:** 2026-08-25  
**Governing Documents:** [Task 1 Contract](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_guarantees_and_non_guarantees.md), [Task 2A Validation Report](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_signal_runtime_validation.md), [Task 3 Detection Model](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_detection_state_model.md), [Task 4 Interventions](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_candidate_interventions.md), [Task 5 Classification](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_logic_vs_data_classification.md), [Task 6 Budget](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_performance_and_battery_budget.md), [ADR-0010](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0010-safari-web-extension-execution-and-update-model.md), [ADR-0012](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0012-native-js-bridge-transport-entitlement-refresh-points.md), [ADR-0013](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0013-layer-3-capability-boundary-and-explicit-non-goals.md)

---

## 1. Scope & Objective

Task 7 defines the **exhaustive failure-mode catalog and regression verification matrix** for the Layer 3 YouTube engine.

### Core Testing Invariants:
1. **The Playback Preservation Invariant:** Every failure, ambiguity, or unexpected state MUST resolve to non-intervention (`NORMAL_PLAYBACK`, `AMBIGUOUS_SAFE`, or `UNKNOWN`). Normal video streaming must never be degraded or frozen by an extension error.
2. **The User Preference Invariant:** SHIELD must **never overwrite a newer user preference** (e.g. manual speed change or unmute) with a stale pre-ad snapshot upon restoration.
3. **The Asynchronous Generation Invariant:** Every asynchronous continuation (`MutationObserver`, `requestAnimationFrame`, `setTimeout`, native message response) **must capture and re-verify its `playerGeneration`** before executing any DOM or media mutation.

---

## 2. Five Failure Domains

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                           FAILURE DOMAINS                               │
├───────────────────────────────────┬─────────────────────────────────────┤
│ Domain                            │ Focus Area                          │
├───────────────────────────────────┼─────────────────────────────────────┤
│ Domain A: Lifecycle & DOM         │ Player mount/dismount, SPA, PiP     │
│ Domain B: Detection Ambiguity     │ False positives, obsolete selectors │
│ Domain C: Intervention Edge Cases │ Acceleration timeouts, user changes │
│ Domain D: Entitlement & Rules     │ ADR-0012 fail-closed vs grace rules │
│ Domain E: Cross-Generation Races  │ In-flight asynchronous continuations│
└───────────────────────────────────┴─────────────────────────────────────┘
```

---

## 3. Comprehensive Failure & Regression Matrix

### Domain A: Player & DOM Lifecycle Failures

| ID | Trigger Condition | Expected FSM State | Allowed Side Effects | Required Restoration | User-Visible Result | Verification Method |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **A-01** | **Player Container Missing at Script Load** (slow feed load or non-video page). | `UNKNOWN` | None. Observer queries for container with single passive retry. | Zero DOM/media mutations. | Normal YouTube feed loads cleanly. | Automated UI test: Load `m.youtube.com` home feed. |
| **A-02** | **Player Replaced Mid-Playback** (SPA navigation starts during video stream). | Transition to `UNKNOWN` $\to$ `NORMAL_PLAYBACK`. | Disconnect previous observer; increment `playerGeneration`. | Restore rate/mute if previously accelerated. | Seamless transition to next video. | Automated UI test: Click related video thumbnail. |
| **A-03** | **SPA Navigation During Active Ad Intervention** (user clicks next video while ad is playing at 16x). | `UNKNOWN` (immediate reset). | Increment `playerGeneration`; drop pending callbacks. | **Immediate unconditional reset** of `playbackRate = 1.0` and `muted = false` on new player. | Next video starts at normal 1.0x speed with audio. | Automated UI test: Navigate during active ad burst. |
| **A-04** | **Fullscreen / PiP Transition** (player viewport size and container classes change). | `NORMAL_PLAYBACK` (unaffected). | FSM evaluates, finds no structural ad class, stays in normal state. | None. | Video expands to fullscreen without stutter. | Manual/Automated test: Enter/exit fullscreen. |
| **A-05** | **Shorts ↔ Long-Form Switch** (different player custom elements: `ytm-mobile-player` vs `ytd-shorts`). | `UNKNOWN` $\to$ `NORMAL_PLAYBACK`. | Re-bind observer to new player container layout. | Clear prior generation state. | Shorts stream smoothly with zero false ad detections. | Automated UI test: Switch from watch page to `/shorts`. |
| **A-06** | **Temporary Duplicate Player Nodes in DOM** (during SPA transition handoff). | `UNKNOWN` $\to$ `NORMAL_PLAYBACK` on active node. | Bind only to active player node matching current generation. | Ignore detached/hidden previous player node. | Normal video streams without dual-observer churn. | Unit test: Mock dual-player container mount. |

---

### Domain B: Detection Failures & Ambiguity

| ID | Trigger Condition | Expected FSM State | Allowed Side Effects | Required Restoration | User-Visible Result | Verification Method |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **B-01** | **`SIG-01` Class Present but Media Inactive** (video paused or buffering on pre-roll). | `AD_CANDIDATE` (held until `mediaActive`). | Zero intervention. Await `play` / `timeupdate`. | None. | Video shows thumbnail/buffer; no premature skip/accel. | Unit test: Inject `.ad-showing` on paused `<video>`. |
| **B-02** | **`SIG-02` Rapid Flapping** (skip button mounts, unmounts within $<50\text{ ms}$). | `AD_CANDIDATE` $\to$ `NORMAL_PLAYBACK` via P5. | No click dispatch if button is unmounted before check. | Yield to non-intervention. | Normal playback resumes without spurious error. | Unit test: Rapid DOM insertion/removal of skip button. |
| **B-03** | **`SIG-03` Text Badge Present Alone** (e.g. video title contains "Ad" or sponsored label). | `NORMAL_PLAYBACK` (Invariant 1 enforced). | Zero intervention. FSM ignores solo `SIG-03`. | None. | Legitimate video plays completely undisturbed. | Unit test: Mount `.ytp-ad-text` with no ad class or skip button. |
| **B-04** | **Conflicting Primary Signals** (Skip button present but player class indicates normal media). | `AMBIGUOUS_SAFE` (via P7). | Record local diagnostic log. Zero DOM/media mutation. | Settle for `safeRecoveryStabilityWindowMs` $\to$ `NORMAL_PLAYBACK`. | Video plays normally without intervention. | Unit test: Mock conflicting DOM state. |
| **B-05** | **DOM Mutation Burst** (external scripts mutate DOM 100+ times/sec during page layout). | `NORMAL_PLAYBACK`. | Bounded observer checks filtered by `attributeFilter: ['class']`. | Zero FSM state churn. | Zero UI lag; frame rate remains steady. | Synthetic load test: Dispatch 500 random DOM mutations. |
| **B-06** | **Obsolete Selectors After YouTube UI Redesign** (YouTube renames ad classes/buttons). | `NORMAL_PLAYBACK` (signals not matched). | Engine fails open cleanly; no elements found. | Yield to native player behavior. | Ad plays natively for 15s; video plays normally afterward. | Unit test: Evaluate FSM with unmatched selector rules. |

---

### Domain C: Intervention Failures & User Control Interactions

| ID | Trigger Condition | Expected FSM State | Allowed Side Effects | Required Restoration | User-Visible Result | Verification Method |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **C-01** | **Synthetic Skip Click Has No Effect** (YouTube ignores synthetic click). | `AD_CONFIRMED` $\to$ Fallback to Accel / Non-Intervention. | Single click dispatched, debounced. | If ad continues, fallback to Candidate C or E. | Ad completes; video resumes normally. | Unit test: Mock skip button ignoring synthetic event. |
| **C-02** | **Skip Button Disappears Before Dispatch** (race between detection and click). | `AD_CONFIRMED` $\to$ `RESET_SETTLING` $\to$ `NORMAL_PLAYBACK`. | Button lookup returns `null`; click aborted cleanly. | None. | Smooth transition to video. | Unit test: Detach button before click execution. |
| **C-03** | **User Manually Changes Playback Speed During Acceleration Burst** (user selects 2.0x in menu). | `AD_CONFIRMED`. | `lastUserRequestedSpeed` updated to `2.0`. | On ad completion, restore `video.playbackRate = 2.0` (NOT pre-ad 1.0x). | Video plays at user's newly chosen 2.0x speed. | Automated UI test: Change speed during ad burst. |
| **C-04** | **User Manually Unmutes / Adjusts Volume During Ad Burst**. | `AD_CONFIRMED`. | `lastUserMutedState` updated to `false`. | On ad completion, keep audio unmuted (preserve user action). | Video remains unmuted. | Automated UI test: Tap unmute during ad burst. |
| **C-05** | **Video Paused by User During Acceleration**. | `AD_CANDIDATE` (since `mediaActive` becomes false). | Pause event halts acceleration loop immediately. | Video remains paused; rate restored to 1.0x. | Video pauses cleanly at current frame. | Automated UI test: User pause during ad. |
| **C-06** | **Acceleration Safety Timeout Expires** (`accelerationSafetyTimeoutMs` reached, e.g. 5s). | Transition to `AMBIGUOUS_SAFE`. | Halt acceleration burst immediately. | **Mandatory unconditional restoration** of `playbackRate` & `muted`. | Playback continues at normal 1.0x speed; no frozen video. | Unit test: Mock ad stuck in playing state $>5000\text{ ms}$. |
| **C-07** | **Restoration Routine Catches an Exception** (media element detached during restore). | `AMBIGUOUS_SAFE`. | Catch error in bounded block; log diagnostic. | Drop reference to detached element cleanly. | Zero uncaught JS errors in console. | Unit test: Force throw in media property restore mock. |

---

### Domain D: Entitlement & Rule-Data Failures (ADR-0012 Conformance)

| ID | Trigger Condition | Expected FSM State | Allowed Side Effects | Required Restoration | User-Visible Result | Verification Method |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **D-01** | **Entitlement Lapses or Check Returns `unavailable`** (Subscription expired or App Group unreadable). | `NORMAL_PLAYBACK` (Layer 3 immediately disabled). | **Fail-Closed Authority Model:** All Layer 3 mitigation hooks halted immediately. | Layer 1 (Content Blockers) & Layer 2 (DNS) continue unaffected. | Ads play natively; zero app crash; zero unauthorized premium filtering. | Unit test: Inject `entitlementState: "unavailable"`. |
| **D-02** | **Rule Generation Unavailable (Within 4-Hour Bound)** (native read fails once). | FSM operates on `storage.local` LKG rules. | **Graceful Degradation:** Use cached valid `rules.json` snapshot. | Retry native pointer read on next refresh point. | Layer 3 continues functioning smoothly. | Unit test: Inject `generationStatus: "unavailable"` with fresh cache. |
| **D-03** | **Rule Generation Unavailable Exceeding 4 Hours**. | `NORMAL_PLAYBACK` (Layer 3 disabled). | Layer 3 halts to prevent running on indefinitely stale selectors. | Await next successful generation update. | Native player operates untouched. | Unit test: Inject `storage.local` cached at $>4\text{ hours}$ old. |
| **D-04** | **Generation Pointer Changes Mid-Video Playback** (OTA update publishes new generation). | Active video finishes on current generation; next SPA nav reloads rules. | Background updates memory cache; active content script keeps current generation until nav. | Zero disruption to ongoing video. | Video stream is uninterrupted. | Unit test: Trigger generation publish during playback. |

---

### Domain E: Cross-Generation Asynchronous Continuation Races

| ID | Asynchronous Continuation Scenario | Detailed Race Sequence | Mandatory Guard & Invariant | Expected Outcome | Verification Method |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **E-01** | **Queued `MutationObserver` Callback vs SPA Navigation** | 1. Observer callback scheduled in microtask queue.<br>2. User clicks new video $\implies \text{playerGeneration}++$.<br>3. Callback fires with old mutations. | ```javascript
if (callbackGen !== playerGeneration) return;
``` | Callback execution aborted immediately; zero DOM/media mutation. | Unit test: Enqueue mutation callback, increment generation, fire callback. |
| **E-02** | **Scheduled `requestAnimationFrame` vs Player Replacement** | 1. `rAF` scheduled for `RESET_SETTLING` settle check.<br>2. Navigation occurs; player element detached.<br>3. `rAF` callback executes. | ```javascript
if (rAFGen !== playerGeneration) return;
``` | `rAF` callback yields immediately without touching detached player. | Unit test: Mock `rAF` execution after generation bump. |
| **E-03** | **Async Message Bridge Response vs Generation Change** | 1. Content script sends `checkVersion` to background.<br>2. SPA navigation occurs before response arrives.<br>3. Native bridge response resolves. | Content script checks captured generation token on response receipt; discards if stale. | Stale configuration is not applied to newly mounted video player. | Unit test: Delay native message response past SPA nav. |
| **E-04** | **Acceleration Safety Timeout vs Navigation** | 1. `setTimeout(safetyTimeout)` armed during ad.<br>2. User navigates away before timeout fires.<br>3. Timeout fires on new video. | ```javascript
if (timeoutGen !== playerGeneration) return;
``` | Timeout handler aborts without altering new video's playback rate. | Unit test: Arm safety timeout, navigate, trigger timer. |
| **E-05** | **Skip-Click Settlement Frame vs Sudden Ad End** | 1. Click dispatched; settlement frame scheduled.<br>2. Ad stream ends naturally before frame runs.<br>3. Settlement frame runs. | Re-evaluates FSM predicates; confirms ad is gone $\to$ transitions `NORMAL_PLAYBACK`. | Player stays in normal playback; no duplicate click. | Unit test: Ad ends during click settlement frame. |
| **E-06** | **Dual Connected Player Elements During Mount Handoff** | 1. Old player element still in DOM during fade-out.<br>2. New player element mounted.<br>3. Observers active on both. | Old observer was disconnected during `playerGeneration++`; only new observer is active. | Old player receives zero callbacks; new player handles state. | Integration test: Simulate YouTube cross-fade SPA transition. |

---

## 4. Acceptance Criteria & Closure Gate Matrix

| Failure Domain | Hard Acceptance Criterion | Verification Tooling |
| :--- | :--- | :--- |
| **Domain A (Lifecycle)** | Zero video playback freezes or black screens on any SPA, PiP, or Shorts transition. | Automated UI Integration Suite |
| **Domain B (Detection)** | Zero false-positive ad triggers on normal video; solo text badges never trigger intervention. | Unit Test FSM State Matrix |
| **Domain C (Intervention)** | 100% exact rate/mute restoration on all exits; user manual adjustments are never clobbered. | Automated Playback Property Suite |
| **Domain D (Entitlement)** | 100% fail-closed on entitlement loss; 4-hour bound strictly enforced on stale rule data. | Native Bridge Mocking Suite |
| **Domain E (Async Races)** | Zero cross-generation callback executions across all 6 asynchronous continuation scenarios. | Concurrency Micro-Harness Suite |

---

## 5. Next Steps

With Task 7 failure modes and regression invariants completely cataloged and bounded:
* **Task 7 Status:** **Complete / Regression Contract Frozen**
* **Next Task:** **Task 8 — Mechanism Decision and Implementation Plan** (Selecting final mechanism architecture and formulating the Sprint 9 implementation roadmap).
