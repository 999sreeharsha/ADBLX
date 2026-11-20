# GitHub Actions Workflows

CI workflow definitions for ADBLX.

`ci.yml` (Sprint 0 Commit 4) runs on manual dispatch only (Actions tab, "Run workflow"; push and pull-request triggers removed 2026-11-20 so pushes don't start a paid macOS run): generates the Xcode project via XcodeGen, fails on drift between `project.yml` and the checked-in `ADBLX.xcodeproj`, builds the `ADBLX` scheme, and runs `ADBLXTests`. `ADBLXUITests` is intentionally excluded (no UI worth testing yet). No caching, no artifacts, no release automation — see `docs/superpowers/specs/2026-07-15-sprint0-commit4-infrastructure-design.md`.
