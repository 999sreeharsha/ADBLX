# ADBLX

iOS/iPadOS/macOS/visionOS ad blocker.

**📖 [docs/TECHNICAL_OVERVIEW.md](docs/TECHNICAL_OVERVIEW.md) — the single source of truth.** Every target, screen, extension, pipeline, the backend, CI/CD, and the backlog. Read that first.

See also [agent.md](agent.md) and [docs/adblock-prd-v1.1.md](docs/adblock-prd-v1.1.md) for product context.

> ⚠️ The per-sprint status sections below are **frozen at Sprint 2** and kept only as history. The project is at Sprint 11+. `TECHNICAL_OVERVIEW.md` is authoritative.

## Getting started

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate `ADBLX.xcodeproj` from `project.yml`. The generated project is committed to git, but if you change `project.yml`, regenerate before opening Xcode:

```bash
brew install xcodegen
xcodegen generate
open ADBLX.xcodeproj
```

Never hand-edit `ADBLX.xcodeproj` directly — edit `project.yml` and regenerate instead.

## Sprint 0 status — complete (`v0.1.0-sprint0`)

- ✅ XcodeGen project (`project.yml` is the source of truth)
- ✅ 7-target architecture (app + 4 Content Blockers + Packet Tunnel + Safari Web Extension)
- ✅ App Group integration (`group.com.ADBLX.shared`)
- ✅ `ADBLXAdsBlocker` Content Blocker extension, embedded and Safari-registered
- ✅ Rule reload (`SFContentBlockerManager.reloadContentBlocker`)
- ✅ App Group rule loading, with permanent bundled-resource fallback
- ✅ End-to-end ad blocking verified manually in Safari (both the App Group and fallback paths)
- ✅ CI (generate/drift-check/build/unit-test on push to `dev`/`main`)

## Sprint 1 status — complete (rule pipeline foundation)

- ✅ Layered rule pipeline for `ADBLXAdsBlocker` — validate → compile → partition → atomically write → reload — replacing Sprint 0's bundled-JSON-copy path
- ✅ `FilterPipeline` actor (dependency-injected via `AppCompositionRoot`, no singleton) sequences six single-purpose stage types under `ADBLX/Filtering/`
- ✅ Atomic writes (`AtomicRuleWriter`: write-temp → fsync → rename) so extensions never observe a partial file, even mid-crash
- ✅ Bounded reload timeout (`ReloadCoordinator`, default 10s) fixing a real Sprint-0 hang incident (extension never enabled in Safari → unbounded callback)
- ✅ `ADBLXAdsBlocker` reads compiled output from `Compiled/Ads.json` (was `Rules/Ads.json` in Sprint 0)
- ✅ `docs/Architecture/Logging.md` — counts/durations/sizes/versions/checksums only, no rule bodies/domains/URLs, no exception for debug builds
- ✅ 28 unit tests (Swift Testing) across 12 suites, all passing; built entirely from bundled test fixtures — no networking yet
- ⏸ Real compilation (`PassthroughRuleCompiler` is a stub, gated on ADR-0001 licensing decision), networking/manifest-driven updates, and the other 3 Content Blockers are all deferred to Part 10

## Sprint 2 status — complete (update pipeline)

- ✅ `Filtering/Updates/` module: fetches `manifest.json` over HTTP (ETag/If-None-Match/304 caching), diffs it against installed filters, downloads and SHA-256-verifies changed filters, installs them transactionally through `FilterPipeline`, and rolls back the entire batch on any failure
- ✅ `UpdatePlanner` — pure diff producing `.install`/`.keep`/`.remove`/`.skipPremium`/`.unsupportedGroup`/`.groupConflict`, no I/O
- ✅ `UpdateCoordinator` — single actor orchestrating fetch → plan → download-all → verify-all → snapshot → install-all (deferred reload) → commit → one reload, or roll back on failure
- ✅ Checksum verification enforced before any App Group write (download-all-then-verify-all-then-snapshot ordering, not just convention)
- ✅ Rollback hardened beyond the original plan: a `FilterStore.restore(_:)` failure surfaces as a typed `.rollbackFailed` result instead of an uncaught throw, snapshot preserved for recovery
- ✅ Fully testable without a real server (`HTTPSession`/`MockHTTPSession` seam) — no test reaches an actual endpoint
- ✅ 40 new tests across 6 new suites + regression coverage on existing suites — 68 tests across 18 suites total, all passing
- ⏸ No real manifest-hosting endpoint, no launch-path/scheduled caller of `UpdateCoordinator.run()` yet, StoreKit/premium purchase flow, multi-group rule composition, and background scheduling are all deferred to Sprint 3+

See [`docs/Architecture/TargetTopology.md`](docs/Architecture/TargetTopology.md) for how it's built, and [`docs/Architecture/ManualVerification.md`](docs/Architecture/ManualVerification.md) for the Sprint 0 verification record. Next milestone: Sprint 3, wiring a real caller of `UpdateCoordinator.run()`.
