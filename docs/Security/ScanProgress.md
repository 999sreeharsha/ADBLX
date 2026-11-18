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
| 4b | Pipeline and Storage | `ADBLX/Filtering/Pipeline`, `ADBLX/Filtering/Storage` | Pending | | |
| 4c | Deployment | `ADBLX/Filtering/Deployment` | Pending | | |

Not covered here:
- **Background-updates staging code:** it's on `feat/background-updates`, which isn't merged.
  Scan it once that branch is built and merged.
- **`Filtering/Entitlement`, `Models` and `Utilities`:** also only partly covered by the first
  audit. Not queued; waiting on the owner.
