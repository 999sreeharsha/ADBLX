# Sprint 0 — Commit 4: Infrastructure (App Groups + CI) Design

**Project:** ADBLX (SHIELD) — iOS Ad Blocker
**Status:** Approved (Final)
**Parent spec:** `docs/superpowers/specs/2026-07-14-sprint0-bootstrap-design.md`

## Goal

Give the app and its extensions a shared container (App Groups) and give the repository continuous verification (GitHub Actions CI). This is the "permissions" commit in Sprint 0's three-commit separation of concerns:

- **Commit 3 (done):** target topology — do the targets exist, do they build.
- **Commit 4 (this one):** permissions and infrastructure — App Groups, CI. No Network Extension entitlement (blocked — see below), no functional App Group I/O.
- **Commit 5:** functionality — real bundled rule snapshots, `reloadContentBlocker()`, App Group round-trip, MetricKit, performance baselines.

## Constraint driving this commit's scope

The Apple Developer account in use is a **Personal Team** (free, non-paid). Personal Teams can provision App Groups, Content Blocker extensions, and Safari Web Extensions, but **cannot** provision the Network Extension entitlement (`com.apple.developer.networking.networkextension`), which `ADBLXPacketTunnel` requires. This is a hard platform restriction, not a project choice.

## 1. App Groups

Identifier: **`group.com.ADBLX.shared`**

This follows the bundle ID namespace already locked in during Commit 2/3 (`com.ADBLX.<TargetName>`), not the originally-proposed-but-superseded `com.sreeharsha.adblx` convention. `TargetTopology.md` already defers bundle ID normalization to a future, not-yet-written ADR; introducing a second naming convention for the App Group would contradict that deferral. If/when that ADR lands and bundle IDs are renamed, the App Group identifier is renamed in the same migration, not before.

### Target matrix

| Target | App Group |
|---|---|
| `ADBLX` | ✅ |
| `ADBLXAdsBlocker` | ✅ |
| `ADBLXPrivacyBlocker` | ✅ |
| `ADBLXAnnoyancesBlocker` | ✅ |
| `ADBLXRegionalBlocker` | ✅ |
| `ADBLXSafariWebExtension` | ✅ |
| `ADBLXPacketTunnel` | ⏸ Deferred — no Network Extension entitlement means no App Group either, to avoid a partially-configured target. Revisit once the account is upgraded to a paid Apple Developer Program membership. |
| `ADBLXTests` | ❌ Not needed |
| `ADBLXUITests` | ❌ Not needed |

Implementation: `entitlements:` block added per-target in `project.yml` (`com.apple.security.application-groups: [group.com.ADBLX.shared]`), consistent with the existing pattern of declaring capabilities inline per target.

## 2. Shared container contract

Directory structure inside the App Group container, documented now as a contract but not yet exercised with real I/O (Commit 5's job):

```
group.com.ADBLX.shared/
├── Rules/
│   ├── Ads.json
│   ├── Privacy.json
│   ├── Annoyances.json
│   └── Regional.json
├── Manifest/
│   └── manifest.json
├── Metadata/
│   ├── installed-versions.json
│   └── manifest-state.json
└── Diagnostics/
```

- `Rules/` (not "CompiledRules") holds the active rule JSON per category, regardless of provenance — bundled, compiled, or imported. Content Blockers will eventually read from here instead of their bundled `Resources/blockerList.json` (that migration is Commit 5). Files are written atomically by the main app (`.tmp` → rename) so extensions never observe partially-written rule files. This is a contract for future write code, not something implemented in this commit.
- `Manifest/manifest.json` — the CDN-fetched manifest describing available filter lists and versions.
- `Metadata/installed-versions.json` — which rule versions are currently installed, self-documenting name (was "versions.json").
- `Metadata/manifest-state.json` — state of the last manifest sync/compile operation, self-documenting name (was "state.json").
- `Diagnostics/` — reserved for future diagnostic output; empty in this commit.

## 3. AppGroup helper

```swift
enum AppGroup {
    static let identifier = "group.com.ADBLX.shared"
}
```

Lives **only in the `ADBLX` app target**. No linkage into `Packages/ADBLXShared` (still gated on unwritten ADR-0003), no duplication into extension targets that have no code referencing the App Group yet. Revisit placement when Commit 5 or ADR-0003 creates a genuine cross-target need.

## 4. GitHub Actions CI

New `.github/workflows/ci.yml`, replacing the current placeholder `README.md`.

**Triggers:**
```yaml
on:
  push:
    branches: [dev, main]
  pull_request:
    branches: [dev, main]
  workflow_dispatch:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

**Runner:** `macos-15`.

**Xcode selection:** `maxim-lobanov/setup-xcode@v1` with `xcode-version: latest-stable`. This resolves to whatever the newest Xcode is on the runner at execution time — no hardcoded path (e.g. `/Applications/Xcode_26.3.app`) that would break silently when GitHub renames, adds, or removes an installed version. As of this writing the newest available is Xcode 26.3 (local dev uses 26.6); documented as a known, temporary gap that closes on its own as GitHub updates its images. No action needed to track it.

**Steps:**
1. Checkout
2. Install XcodeGen (`brew install xcodegen`)
3. `xcodegen generate`
4. Verify no drift: `git diff --exit-code ADBLX.xcodeproj` (fails the build if generation changed the checked-in project file)
5. `xcodebuild build` for the `ADBLX` scheme
6. `xcodebuild test` — **`ADBLXTests` only**, via `-only-testing:ADBLXTests`

**CI philosophy:** each step gates the next — the pipeline validates repository state before it validates code. Generation must succeed before the drift check runs; the drift check is a hard failure (not a warning) before build; build must succeed before tests run. There is no `fail-fast: false` matrix here (single job, no parallel variants), but the ordering itself is the fail-fast contract: a broken step stops the pipeline rather than masking downstream results.

**Sprint 0 CI test policy (explicit):**
```
Run:  ADBLXTests
Skip: ADBLXUITests
```
Reason: not flakiness avoidance — there is currently no UI worth testing. `ADBLXUITests` joins CI once onboarding/settings screens exist in a later sprint.

No caching, no artifacts, no release automation.

## Acceptance criteria

1. App Group entitlement present on the 6 supported targets (`ADBLX` + 4 Content Blockers + `ADBLXSafariWebExtension`); absent on `ADBLXPacketTunnel`, `ADBLXTests`, `ADBLXUITests`.
2. `xcodegen generate` is idempotent — running it twice produces no further diff.
3. `xcodebuild build` succeeds locally for all 7 non-test targets plus `ADBLXTests`/`ADBLXUITests` compilation.
4. No provisioning/entitlement warnings in Xcode's project navigator for any target.
5. `.github/workflows/ci.yml` exists and a push to `dev` produces a passing run (generate → drift check → build → `ADBLXTests`).
6. `TargetTopology.md` updated: App Group section added (identifier, target matrix, PacketTunnel-deferred rationale tied to the Personal Team constraint), shared container contract documented, CI section added.
7. `ADBLXPacketTunnel` remains entirely unmodified — no entitlement, no App Group, no capability change of any kind.

## Performance & battery

No runtime impact. App Groups add a negligible entitlement/container overhead with no code yet reading or writing through it. CI changes are developer-workflow-only — no effect on the shipped app. The only measurable cost is CI wall-clock time from building 7 targets, which is not gated in this commit.

## Development environment limitations

Current development uses an Apple Personal Team (free, non-paid). Therefore:

- The Network Extension entitlement (`com.apple.developer.networking.networkextension`) is unavailable — Personal Teams cannot provision it.
- `ADBLXPacketTunnel`'s capability and App Group are intentionally deferred as a result (see the target matrix above).
- This is an Apple provisioning limitation, not a project or architecture limitation. Revisit once the account upgrades to a paid Apple Developer Program membership.

## What's deliberately not here

- Network Extension entitlement / App Group for `ADBLXPacketTunnel` — blocked on Personal Team; revisit after upgrading to a paid Apple Developer Program membership.
- Any App Group read/write code — Commit 5.
- `ADBLXShared` package linkage / ADR-0003 — separate, not pulled into this commit's scope.
- `ADBLXUITests` in CI — deferred until there's UI worth testing.
- CI caching, build artifacts, release automation.
