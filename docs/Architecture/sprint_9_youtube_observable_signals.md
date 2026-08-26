# Sprint 9 — Task 2: Observable YouTube Page-State Signals

**Status:** Proposed / Candidate Catalog (Pending Task 2A Runtime Validation)  
**Date:** 2026-08-25  
**Governing Documents:** [Task 1 Contract](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_guarantees_and_non_guarantees.md), [ADR-0010](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0010-safari-web-extension-execution-and-update-model.md), [ADR-0013](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0013-layer-3-capability-boundary-and-explicit-non-goals.md)

---

## 1. Scope & Execution Boundary

This catalog identifies and evaluates candidate **page-local signals** on `m.youtube.com` and `www.youtube.com` in iOS/iPadOS Safari.

Per ADR-0010 and Safari Web Extension security architecture:
* **Content scripts run in an Isolated World.** They share the live DOM tree with the web page but **do not** share JavaScript heap execution context.
* Global page variables (e.g., `window.ytplayer`, `window.ytInitialData`, internal Polymer element methods) are **not synchronously accessible** to the content script.
* Dynamic DOM `<script>` injection into the page context to extract page-world state is **prohibited** (violates App Store 2.5.2 compliance & ADR-0010 executable boundaries).
* **Only signals observable directly from the content script via standard DOM and W3C Media APIs are admitted.**

---

## 2. Candidate Signal Catalog (Pending Task 2A Validation)

### Category A: Video Ad Detection & Media Lifecycle Signals

| Signal ID | Candidate Signal Description | Source | Observable in Content Script? | Classification: Stable Data vs Logic | Initial False-Positive Risk Hypothesis | Runtime Cost |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **SIG-01** | **Player Container Ad Classes**<br>*(Candidate selectors: `.ad-showing`, `.ad-interrupting` on `#player`, `.html5-video-player`, or mobile player container)* | DOM Attribute / ClassList | **YES**<br>(Direct DOM access) | **Selector Data**<br>(Updatable class names) | **Low (Hypothesis)**<br>(Class applied during ad state) | **Low**<br>(Event/mutation triggered) |
| **SIG-02** | **Skip Control Element Presence**<br>*(Candidate selectors: `.ytp-ad-skip-button`, `.ytp-skip-ad-button`, `.ytm-skip-ad-button`, ARIA role)* | DOM Subtree Query | **YES**<br>(Direct DOM query) | **Selector Data**<br>(Updatable selector list) | **Low (Hypothesis)**<br>(Skip controls indicate ad state) | **Low**<br>(Scoped lookup) |
| **SIG-03** | **Ad Text / Badge Overlay Elements**<br>*(Candidate selectors: `.ytp-ad-text`, `.ytm-ad-badge`, "Ad ·", countdown timer overlays)* | DOM Subtree & TextContent | **YES**<br>(Direct DOM query) | **Selector Data + Fixed String Match** | **Moderate (Ambiguous)**<br>(Must NEVER act as solo authorizer) | **Low**<br>(Corroborating only) |
| **SIG-05** | **W3C `<video>` Element Events**<br>(`play`, `playing`, `pause`, `durationchange`, `timeupdate`, `ended`) | Standard HTMLMediaElement API | **YES**<br>(DOM Event Listeners) | **Fixed Logic**<br>(Standard browser event bindings) | **Zero (Neutral Trigger)**<br>(Lifecycle indicator) | **Low**<br>(Passive event listeners) |
| **SIG-06** | **`<video>` Element Properties**<br>(`duration`, `currentTime`, `paused`, `playbackRate`) | Standard HTMLMediaElement API | **YES**<br>(Direct DOM property reads) | **Fixed Logic**<br>(W3C standard properties) | **High alone; Zero secondary**<br>(Cannot deduce ads by duration alone) | **Negligible**<br>(In-memory read) |
| **SIG-07** | **Player Subtree Mutation Events**<br>(Child additions/removals inside player container) | `MutationObserver` API | **YES**<br>(Scoped observer) | **Fixed Logic + Updatable Selector** | **Medium**<br>(Player mutates during UI & buffering) | **Low if scoped & debounced** |

---

### Category B: Cosmetic & Feed Target Selectors (Independent of Video Playback)

| Signal ID | Target Description | Source | Observable in Content Script? | Classification: Stable Data vs Logic | Purpose | Runtime Cost |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **SIG-04** | **Companion / Feed Banner Renderers**<br>*(Candidate selectors: `ytm-promoted-sparkles-web-renderer`, `ytm-companion-ad-renderer`, `.ad-container`)* | DOM Elements (Feed & Sidebar) | **YES**<br>(Direct DOM query) | **Selector Data**<br>(Updatable element tags & classes) | **Cosmetic Hiding/Removal**<br>(Does NOT indicate video playback state) | **Low**<br>(Declarative CSS injection or element removal) |

---

### Category C: Inadmissible Signals

| Signal ID | Signal Description | Source | Observable in Content Script? | Classification | Reason for Rejection |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **SIG-08** | **Page Context JS Objects**<br>(`window.ytInitialPlayerResponse`, `ytplayer.config`) | Page JS Heap | **NO**<br>(Isolated world barrier) | **Inadmissible** | Inaccessible without prohibited dynamic script injection (violates ADR-0010 & App Store 2.5.2) |

---

## 3. Signal Trust Hierarchy & Composition Rules

To enforce the **Cardinal Rule of Playback Preservation** (Task 1), Task 3 must observe the following signal trust constraints:

```text
[Primary Structural Signals]
SIG-01 (Player Ad Class) OR SIG-02 (Skip Control Presence)
                       │
                       ▼
[Corroborating State Signals]
+ SIG-05 / SIG-06 (Media Playing & Active Time)
+ SIG-03 (Ad Badge / Text Indicator - Corroborating Only)
                       │
                       ▼
       [Validated Video Ad State Transition]
```

1. **Text/Badge Indicators (SIG-03) Must Never Independently Authorize Interventions:**
   - Text strings like "Ad" or "Sponsored" can appear in legitimate video titles, comments, or descriptions. SIG-03 may only corroborate a structural signal (SIG-01 or SIG-02), never trigger an ad state on its own.
2. **Cosmetic Targets (SIG-04) Are Strictly Decoupled from Video State:**
   - Banner and feed item suppression is handled through cosmetic rules and does not interact with the video player state machine.

---

## 4. Task 2A — Signal Runtime Validation Gate

Before any candidate selector or signal is adopted into Task 3's state model, it must be verified empirically in **Task 2A** against live Safari surfaces.

### Runtime Validation Matrix

| Candidate Signal | `www.youtube.com` (Desktop Safari) | `m.youtube.com` (Mobile Safari) | iOS Safari | iPadOS Safari | False Positive on Normal Playback? | Ad State Positively Observed? |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **SIG-01** (Player Classes) | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] |
| **SIG-02** (Skip Controls) | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] |
| **SIG-03** (Ad Badges/Text) | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] |
| **SIG-04** (Feed/Banners) | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] |
| **SIG-05/06** (Media Events/Props)| [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] |
| **SIG-07** (Scoped Mutation) | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] | [ Pending ] |

### Validation Test Flows
Runtime evaluation must test across:
1. Normal long-form video playback (verification that no ad state triggers).
2. YouTube Shorts playback (ensuring short duration does not trigger false positive).
3. Skippable video ad presentation.
4. Non-skippable video ad presentation.
5. In-feed and companion banner presence.
6. SPA navigation (client-side video switching without full page reload).
7. Fullscreen and Picture-in-Picture (PiP) transitions.
8. Non-ad playback after an ad concludes.

> [!NOTE]
> **Zero Telemetry Rule:** Signal validation is performed via development-only DOM inspection and local console diagnostic harnesses. No tracking, logging, or telemetry is shipped to production.

---

## 5. Next Steps

* **Task 2 Status:** Proposed / Candidate Catalog Complete
* **Prerequisite Gate:** **Task 2A — Signal Runtime Validation** (capture empirical evidence for matrix).
* **Downstream:** **Task 3 — Detection-State Model** (will incorporate only signals validated in Task 2A).
