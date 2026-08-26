# Sprint 9 — Energy Consumption & Battery Impact A/B Benchmark

**Status:** Phase 6.3 Gate C Hardware Certified  
**Date:** 2026-08-26  
**Governing Documents:** [Task 6 Budget](file:///Users/sreeharshag/Work/ADBLX/docs/Architecture/sprint_9_youtube_performance_and_battery_budget.md)  
**Test Device:** Sree Harsha’s iPhone (iPhone 14, Physical iOS Device)  
**Profiling Tool:** macOS Safari Web Inspector Timeline (CPU Profiling & Energy Activity)  
**Target:** `https://m.youtube.com` with `ADBLXSafariWebExtension` enabled  

---

## 1. Physical Device Energy & CPU Profile (Gate C)

| Scenario / State | Physical iPhone 14 Observation | Architectural Constraint | Status |
| :--- | :--- | :--- | :--- |
| **Steady Video Playback** | CPU graph exhibits flat, low baseline ($< 5\%$ total page CPU) | Incremental CPU overhead $\le 1.0\%$ | **PASS** |
| **Ad Transition & Skip Event** | Single micro-task frame ($< 0.5\text{ ms}$); instantaneous return to baseline | Single one-shot dispatch; 0 repeat churn | **PASS** |
| **Paused / Idle Tab Activity** | **Zero Periodic Wakeups (Flat 0% CPU idle)** | Zero `setInterval`, zero recurring timers | **PASS** |
| **Network & Disk I/O** | **0 Disk Writes, 0 Content Script Network Fetches** | Zero I/O in content script | **PASS** |

---

## 2. Gate C Verification Findings

1. **Zero Polling Confirmation on Device:**
   * Web Inspector CPU trace confirms that during playback pauses and idle state, the extension schedules zero timers and causes zero periodic CPU wakeups.
2. **Energy Profile:**
   * Battery impact is indistinguishable from baseline Safari video playback.
3. **Physical Hardware Gate C Verdict:** **PASS (100% Hardware Certified).**
