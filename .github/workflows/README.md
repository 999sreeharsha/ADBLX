# GitHub Actions Workflows

CI workflow definitions for ADBLX.

`ci.yml` (Sprint 0 Commit 4) runs on push/PR to `dev`/`main` and on manual dispatch: generates the Xcode project via XcodeGen, fails on drift between `project.yml` and the checked-in `ADBLX.xcodeproj`, builds the `ADBLX` scheme, and runs `ADBLXTests`. `ADBLXUITests` is intentionally excluded (no UI worth testing yet). No caching, no artifacts, no release automation — see `docs/superpowers/specs/2026-07-15-sprint0-commit4-infrastructure-design.md`.
