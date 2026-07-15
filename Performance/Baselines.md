# Performance Baselines

Tracked performance baselines for ADBLX, established in Sprint 0 Commit 5. Update in place as the app grows — each entry should be dated so regressions are visible over time.

## Build time (7 targets: `ADBLX` + 6 extensions)

| Date | Real time | Notes |
|---|---|---|
| 2026-07-15 | 12.8s | Clean build, DerivedData wiped, `generic/platform=iOS Simulator`, Xcode 26.6, Sprint 0 Commit 5 baseline. |

## Cold launch (Time Profiler)

| Date | Time to first frame | Notes |
|---|---|---|
| Not yet captured | — | Requires manual Instruments capture (Product → Profile → Time Profiler) — not automatable from the CLI. Capture before relying on this baseline for regression tracking. |

## `ADBLXAdsBlocker` memory (Allocations)

| Date | Peak memory | Budget | Notes |
|---|---|---|---|
| Not yet captured | — | ~6MB (per `agent.md`'s Content Blocker hard constraint) | Requires manual Instruments capture (Product → Profile → Allocations, attached to the running extension process triggered via Safari) — not automatable from the CLI. |

## Methodology

- Build time: `time xcodebuild ... build` after wiping `~/Library/Developer/Xcode/DerivedData/ADBLX-*`.
- Cold launch / memory: Xcode → Product → Profile → Time Profiler / Allocations, manual capture — no automated performance test exists yet.
