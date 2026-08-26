# Sprint 9 — Task 1: YouTube-in-Safari Guarantees and Non-Guarantees

**Status:** Proposed / Ready for Validation  
**Date:** 2026-08-25  
**Governing ADRs:** [ADR-0010](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0010-safari-web-extension-execution-and-update-model.md), [ADR-0011](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0011-web-extension-rule-data-generation-lifecycle-and-publication.md), [ADR-0012](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0012-native-js-bridge-transport-entitlement-refresh-points.md), [ADR-0013](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0013-layer-3-capability-boundary-and-explicit-non-goals.md)

---

## 1. Context & Purpose

In Layer 3 (Safari Web Extension), YouTube ad mitigation is the most visible and technically dynamic feature. YouTube frequently adjusts player architecture, DOM class names, injection timing, and anti-adblock countermeasures.

Per ADR-0010, **all executable JavaScript logic in SHIELD is fixed at app release**; only non-executable rule data (selectors, domain matches, thresholds, flags) updates over the air. Furthermore, per ADR-0013, YouTube mechanism design is strictly deferred until explicit guarantees and admission tests are defined.

This document establishes the **product contract**: what SHIELD promises, what it disclaims, its failure philosophy, and the exact boundaries of user-facing claims. All technical detection models (Task 2–8) are measured against this contract.

---

## 2. What SHIELD Honestly Guarantees

SHIELD guarantees the following capabilities on supported platforms (**Safari on iOS/iPadOS 17+**):

1. **Client-Side Ad Interstitial Mitigation on Supported Safari YouTube Domains:**
   - On `m.youtube.com` and `www.youtube.com` accessed via Safari, when supported client-side advertisement state indicators are positively identified by the validated Layer 3 mechanism, SHIELD will apply the corresponding approved mitigation.
2. **Zero Native Code Injection or Remote Code Evaluation:**
   - SHIELD guarantees that YouTube filtering executes strictly via bundled, statically audited JavaScript and published data definitions. No remote scripts or arbitrary strings are ever evaluated (`eval()`, `new Function()`, dynamic script tag injection are strictly absent).
3. **Fail-Closed Entitlement Enforcement:**
   - Layer 3 YouTube enhancement runs only when valid premium entitlement is confirmed. If entitlement is missing or expired, Layer 3 features halt immediately without degrading standard Content Blocker (Layer 1) or DNS (Layer 2) operations.
4. **Clean DOM Observer Teardown & Battery Discipline:**
   - DOM observation is scoped to the active relevant player/page subtree and is disconnected when the content script's bounded observation purpose is complete or the page context is torn down. Backgrounding is not relied upon as the sole teardown mechanism. No unbounded global listeners or polling loops will run on idle or non-video pages.

---

## 3. What SHIELD Explicitly Does Not Guarantee

SHIELD explicitly **does not** guarantee:

1. **Native YouTube App Filtering (PRD Non-Goal NG1):**
   - SHIELD cannot inspect, block, or modify ads within the standalone Google YouTube iOS application. iOS sandboxing and lack of extension hooks make native app traffic inspection impossible under standard App Store guidelines.
2. **Seamless Defeat of Server-Stitched Video Ads:**
   - If YouTube serves advertisement segments spliced directly into the main HLS/DASH video media stream without distinct client-side DOM markers or player state events (server-side ad insertion / SSAI), SHIELD cannot guarantee segment excision without risking video stream corruption.
3. **Zero-Day Resilience Against Architectural Changes Requiring New Logic:**
   - If YouTube rewrites its internal web player framework such that mitigation requires a fundamentally new algorithmic state machine (rather than updating CSS selectors or timing thresholds via ADR-0011 data), mitigation will temporarily degrade until an updated app binary is reviewed and released via the App Store.
4. **Permanent Immunity to Anti-Adblock Script Evolution:**
   - SHIELD does not guarantee an uninterrupted arms race victory against YouTube's anti-adblock countermeasures. When YouTube deploys a novel detection script, SHIELD will prioritize stability and playback preservation over aggressive, brittle bypasses.
5. **Desktop macOS or visionOS Safari (Deferred Scope):**
   - Per ADR-0010 Decision 5, Safari Web Extension behavior on macOS and visionOS is not covered by Sprint 9 guarantees.

---

## 4. Failure Philosophy: Playback Preservation Over Aggressive Intervention

When designing and executing detection and intervention algorithms, the following hierarchy of invariants governs all decisions:

```text
[Highest Priority]
1. Normal Video Playback Integrity (Video plays, audio syncs, controls respond)
2. User Security & Privacy (No external tracking, no dynamic code execution)
3. Ad Suppression & Cosmetic Cleanup (Hiding overlays, mitigating ad interruptions)
[Lowest Priority]
```

### The Cardinal Rule of Ambiguity
> **When uncertain whether content is an advertisement or legitimate video/player UI, SHIELD MUST prefer non-intervention over risking corruption of normal playback.**

### Rationale:
* An unblocked ad is an annoyance for 15 seconds.
* A broken video player (black screen, frozen buffer, unresponsive playback, broken full-screen mode) completely destroys the user's browser utility and generates immediate 1-star App Store reviews.
* Detection must use validated, bounded criteria. Where signals are ambiguous, the mechanism must preserve the cardinal rule and yield without intervention.

---

## 5. Candidate Claim Boundaries (Subject to Sprint 9 Mechanism Validation)

To ensure product honesty, App Store compliance, and alignment with engineering realities, the following claim boundaries are established:

| Candidate Permitted Claims (Subject to Validation) | Prohibited Claims (Overpromising / False) |
| :--- | :--- |
| "Mitigates video ads and sponsored banners on YouTube in Safari" | "100% ad-free YouTube forever" |
| "Enhanced YouTube web protection on iOS & iPadOS" | "Blocks ads in the YouTube app" |
| "Fast, battery-efficient video ad mitigation in Safari" | "Unbreakable ad blocking that YouTube cannot detect" |
| "Clean, distraction-free YouTube browsing in Safari" | "Eliminates all commercial video interruptions across iOS" |

---

## 6. Technical Task Execution Roadmap

With the contract set, technical design proceeds through the remaining seven stages:

```text
Task 1  [DONE] → User-facing guarantees and non-guarantees contract
Task 2  [DONE] → Observable YouTube page-state signals (Candidate catalog)
Task 2A [GATE] → Signal runtime validation matrix
Task 3         → Detection-state model (State predicates, bounded transitions)
Task 4         → Candidate interventions (CSS hide, playback-state manipulation, skip trigger)
Task 5         → Fixed logic vs updatable data classification (Schema definition)
Task 6         → Performance / observer lifecycle / battery budget
Task 7         → Failure modes and regression matrix
Task 8         → Mechanism decision and implementation plan
```
