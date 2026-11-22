# Security scan progress: areas never scanned

Scans of the areas `Findings.md` lists as never in a scan's scope, run one area at a time.
Each area is marked done here, and committed, before the next starts. If a scan stops partway
(usage limits, a crash), resume at the first area not marked done; don't rerun finished areas.

Branch: `chore/security-scan-gaps`, based on `feat/plan-state-downgrade` at `4bca27e`.
Effort: medium, Claude Security three-voter panel. Reports go to the gitignored
`CLAUDE-SECURITY-<timestamp>/` folder at this worktree's root. Findings are added to
`Findings.md` as Open for review; nothing is fixed.

| # | Area | Scope | Status | Report | Findings |
|---|---|---|---|---|---|
| 1 | CI and backend publishing | `.github/`, `backend/` except `backend/tools/Publisher` | Done 2026-11-08, verified (6/6 researchers returned) | `CLAUDE-SECURITY-20261108-105440` | None |
| 2 | Protection feature | `ADBLX/Features/Protection` | Done 2026-11-08, verified (6/6 researchers returned) | `CLAUDE-SECURITY-20261108-110119` | None |
| 3 | Home and Onboarding features | `ADBLX/Features/Home`, `ADBLX/Features/Onboarding` | Done 2026-11-08, verified (10/10 researchers returned) | `CLAUDE-SECURITY-20261108-110741` | One LOW, already SEC-16 (confirmed again, 3/3) |

Areas 1 to 3 are done.

## Area 4: `ADBLX/Filtering` (approved 2026-11-09, started 2026-11-18)

The first audit scan covered `Filtering` only partly, and most new security code since then
lives here: manifest signature verification, the list download cap, the commit and restore
changes, and the compiler-version recompile. Branch `chore/security-scan-filtering`, based on
`feat/plan-state-downgrade` at `2766c70`. `Pipeline/` (2 files) is scanned with `Storage/` so it
gets the full set of category lenses instead of a single researcher.

| # | Part | Scope | Status | Report | Findings |
|---|---|---|---|---|---|
| 4a | Updates | `ADBLX/Filtering/Updates` | Done 2026-11-18, verified (6/6 researchers returned) | `CLAUDE-SECURITY-20261118-125547` | None; two candidates rejected 3/0, kept as bug notes in `Findings.md` |
| 4b | Pipeline and Storage | `ADBLX/Filtering/Pipeline`, `ADBLX/Filtering/Storage` | Done 2026-11-18, verified (6/6 researchers returned) | `CLAUDE-SECURITY-20261118-130757` | None |
| 4c | Deployment | `ADBLX/Filtering/Deployment` | Done 2026-11-18, verified (2/2 researchers returned; small-scope shape, one all-category researcher) | `CLAUDE-SECURITY-20261118-131629` | None |

Area 4 is done.

## Area 5: background-updates staging code (approved 2026-11-22, run on `dev`)

`feat/background-updates` merged into `dev` on 2026-11-20 (`53c59b6`). Its staging code was
never in a scan's scope. Don't start until the owner says go. Run it on `dev` (or a short-lived
branch from it), with the same effort and panel as above.

| # | Part | Scope | Status | Report | Findings |
|---|---|---|---|---|---|
| 5 | Background updates | What `feat/background-updates` added or changed in production code: `ADBLX/Filtering/Updates/BackgroundTaskIdentifiers.swift`, `ADBLX/Filtering/Updates/UpdateCoordinator.swift`, `ADBLX/Filtering/Storage/FilterStore.swift`, `ADBLX/Filtering/Storage/LaunchRecovery.swift`, `ADBLX/Filtering/Pipeline/FilterPipeline.swift`, `ADBLX/Filtering/Deployment/PendingReloads.swift`, `ADBLX/Filtering/Entitlement/PremiumEntitlementReconciler.swift`, `ADBLX/LaunchSequence.swift`, `ADBLX/ADBLXApp.swift`, `ADBLX/Features/Settings/Developer/BackgroundTiming.swift` and `DeveloperDiagnosticsView.swift` (DEBUG only) | Done 2026-11-22, verified (6/6 researchers returned), at `f247093` | `CLAUDE-SECURITY-20261121-211539` | None; two LOW candidates rejected 3/0, one kept as a bug note in `Findings.md` (stale `premium` flag) |

Area 5 is done.

## Areas 6 and 7 (approved 2026-11-22, run on `dev`)

The first audit covered `Filtering/Entitlement` and `Utilities` only partly, and the Area 5
researchers read the rule compiler only as background. Run on `dev` after `3caf8a7` (the
tier-change fix), so Area 6 reads the reconciler as it is now. Same effort and panel as above.

| # | Part | Scope | Status | Report | Findings |
|---|---|---|---|---|---|
| 6 | Entitlement and Utilities | `ADBLX/Filtering/Entitlement`, `ADBLX/Filtering/Utilities` | Queued | | |
| 7 | Rule compiler | `Packages/ADBLXShared/Sources/ADBLXShared/Compiler`, `ADBLX/Filtering/Compilation`, `ADBLX/Filtering/Deployment/RulePartitioner.swift` | Queued | | |

Not covered here:
- **`Filtering/Models`:** also only partly covered by the first audit (data types). Not queued.
