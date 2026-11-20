# Scripts

Build, lint, and automation helper scripts for ADBLX.

**Archive checks** run as build phases of the `ADBLX` target and act only when archiving
(`ACTION=install`), so an archive fails without CI:

- `check-report-recipient.sh` and `check-manifest-trust.sh` (before compiling).
- `check-archive-release.sh` (last phase, after the extensions are embedded): runs
  `check-release-no-dns.sh`, `check-extension-versions.sh` and `check-background-modes.sh` on the
  app being archived, and checks
  the entitlements it will be signed with.

Each `*.test.sh` beside a check exercises it; run them after changing a check.
