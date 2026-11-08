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
| 3 | Home and Onboarding features | `ADBLX/Features/Home`, `ADBLX/Features/Onboarding` | Pending | | |

Not queued (waiting on the owner): the `ADBLX/Filtering` folders the first audit scan only
partly covered (everything except `DNS`, `WebExtension`, `Compilation`, `Validation`,
`Storage` and `Deployment`).
