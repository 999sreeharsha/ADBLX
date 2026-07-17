# Filtering module — target placement

**This entire module belongs in the main app target ONLY.**

- Do NOT add this module, or any file in it, to `Packages/ADBLXShared`. Shared-package adoption
  is gated on ADR-0003, which is not yet approved.
- Do NOT add this module to any Content Blocker extension target. Extensions read pre-compiled
  JSON from the App Group container and nothing else — they have a ~6MB memory ceiling and
  cannot host compilation, validation, or networking code.
- `FilterStore` (Storage/) is the *only* type permitted to touch the App Group container
  filesystem. If you need filesystem access elsewhere, route it through `FilterStore` instead
  of opening a new path.
- `RuleStatistics` and any diagnostics/logging must contain counts and durations only — never
  rule bodies, domains, hostnames, or URLs. See `docs/Architecture/Logging.md`.
- Every non-actor type in this module (`FilterValidator`, `RuleCompiler`, `RulePartitioner`,
  `AtomicRuleWriter`, `Checksum`) is explicitly `nonisolated` because the `ADBLX` target builds
  with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` — see the plan's Global Constraints for why.

Sprint 1 scope: bundled test fixtures only, no networking until Part 10. `Compilation/` ships a
passthrough `RuleCompiler`, not a real compiler — see
`docs/superpowers/specs/2026-07-17-sprint1-rule-pipeline-design.md`.
