# Agent Notes — SHIELD (ADBLX)

iOS/iPadOS/macOS/visionOS ad blocker.

> **Start here:** [`docs/TECHNICAL_OVERVIEW.md`](docs/TECHNICAL_OVERVIEW.md) is the single source of truth — every target, screen, extension, pipeline, the backend, CI/CD, and the backlog. The "Current repo state" section further down this file is frozen at Sprint 2 and is **historical only**; trust `TECHNICAL_OVERVIEW.md` where they disagree.

Full product spec: [docs/adblock-prd-v1.1.md](docs/adblock-prd-v1.1.md) (treat §9 monetization and §12 sprint plan as superseded — see [`docs/Architecture/PD-01-monetization-and-trial.md`](docs/Architecture/PD-01-monetization-and-trial.md)).

**Note:** the Xcode project as scaffolded also targets native macOS and visionOS (`supportedDestinations: [iOS, macOS, visionOS]`), not Mac via Catalyst as this line previously stated. That scope was inherited from Xcode's default multiplatform template and deliberately preserved, not decided, during Sprint 0's XcodeGen migration — see [`docs/Architecture/TargetTopology.md`](docs/Architecture/TargetTopology.md#multiplatform-scope). Treat the PRD's "iOS/iPadOS/Mac(Catalyst)" framing as the product intent pending a future Platform Strategy ADR, not as a description of the current build's platform scope.

## What it does
Blocks ads/trackers in Safari (content blockers) and, for premium, device-wide via an on-device DNS tunnel + YouTube-in-Safari web extension. Zero data collection is a hard constraint.

## Architecture (3 layers)
1. **Safari Content Blockers ×4** (Ads/Privacy/Annoyances/Regional) — declarative JSON, ≤150K rules each, no runtime cost.
2. **Local DNS tunnel** (`NEPacketTunnelProvider`, premium) — on-device only, no remote servers/logging.
3. **Safari Web Extension** (premium) — JS for YouTube ad blocking + cosmetic filtering.

Filter lists are fetched/compiled client-side from a CDN manifest (no app-update needed for new lists).
Details: [§6 Architecture](docs/adblock-prd-v1.1.md#6-architecture).

## Hard constraints (don't violate)
- No third-party analytics/SDKs touching browsing data (G5).
- Never claim in-app YouTube/Facebook ad blocking — Safari only (NG1).
- No on-device ML/per-query inference on the tunnel hot path (NG6).
- Content blocker rule compiling happens **only in the main app**, never in extensions (~6MB memory limit).
- Filter licenses are GPL/CC-BY-SA — attribution + legal review required before shipping (see [§10](docs/adblock-prd-v1.1.md#10-app-store-compliance--risks)).

## Where to look for detail
| Topic | Section |
|---|---|
| Feature scope / free vs premium | [§5](docs/adblock-prd-v1.1.md#5-product-scope) |
| Full functional requirements (FR-01..15) | [§7](docs/adblock-prd-v1.1.md#7-functional-requirements) |
| Non-functional targets (perf/battery/etc.) | [§8](docs/adblock-prd-v1.1.md#8-non-functional-requirements) |
| Monetization / pricing | [§9](docs/adblock-prd-v1.1.md#9-monetization) |
| Sprint plan | [§12](docs/adblock-prd-v1.1.md#12-milestones-sprint-plan) |
| Open questions (unresolved decisions) | [§13](docs/adblock-prd-v1.1.md#13-open-questions) |
| Reference codebases to study (AdGuard iOS, SafariConverterLib) | [Appendix B](docs/adblock-prd-v1.1.md#15-appendix-b--reference-architectures-study-material) |
| India proprietary filter list plan | [Appendix C](docs/adblock-prd-v1.1.md#16-appendix-c--indian-web-ad-network-filter-list-proprietary-regional-extension) |

## Current repo state
Sprint 2 (update pipeline) is **complete** on `dev`, all 10 tasks landed:
- A new `Filtering/Updates/` module (main app target only, flat, six files) owns manifest fetch/cache, filter download, and orchestration: `HTTPSession` (protocol seam over `URLSession`, with a `MockHTTPSession` test double), `ManifestClient` (fetches `manifest.json`, ETag/If-None-Match/304 support), `ManifestStore` (persists the cached manifest+ETag via `FilterStore`), `FilterDownloadClient` (downloads one filter to a temp file), `UpdatePlan.swift` (`UpdatePlanner` — pure diff of manifest vs. installed filters, producing `.install`/`.keep`/`.remove`/`.skipPremium`/`.unsupportedGroup`/`.groupConflict`), and `UpdateCoordinator` (the top-level actor tying all of it together into one transaction: fetch → plan → download-all → verify-all → snapshot → install-all-deferred → commit → single reload, or roll back the whole batch on failure).
- Two small additive changes to Sprint 1 types, both backward-compatible: `FilterPipeline.install` gained `version:`/`reloadStrategy:` parameters (both defaulted, so the one existing Sprint 1 caller is unaffected) and now accumulates `installed_filters.json` by filter ID instead of overwriting it; `FilterStore` gained `snapshotForRollback()`/`restore(_:)` for batch rollback via a transient `Previous/` directory. `ReloadCoordinator` is untouched.
- A design gap surfaced mid-plan and was deliberately hardened beyond the original plan text: `FilterStore.restore(_:)` isn't atomic (a failure mid-copy could leave `Compiled/`/`Metadata/` partially wiped), so `UpdateCoordinator.run()` gained a `.rollbackFailed(originalReason:restoreError:)` result case — a restore failure now surfaces as a typed result instead of an uncaught throw, and the `Previous/` snapshot is left on disk for recovery rather than deleted.
- Checksum verification (`Checksum.verify(fileURL:against:)`, new on the existing `Checksum` enum) runs on every downloaded filter before any App Group write — enforced by code structure (download-all-then-verify-all-then-snapshot), not just by convention.
- Networking is fully testable without a real server via `HTTPSession`/`MockHTTPSession` — no test in this sprint reaches an actual endpoint.
- 40 new unit tests across 6 new suites (`HTTPSessionTests`, `UpdatePlannerTests`, `ManifestStoreTests`, `ManifestClientTests`, `FilterDownloadClientTests`, `UpdateCoordinatorTests`), plus regression coverage added to the existing `FilterPipelineTests`/`FilterStoreTests`/`ChecksumTests` — 68 tests across 18 suites total, all passing.
- Not yet done, intentionally out of scope this sprint (see "What's deliberately not here yet" in [`TargetTopology.md`](docs/Architecture/TargetTopology.md)): no real manifest-hosting endpoint, no launch-path or scheduled caller of `UpdateCoordinator.run()` yet (nothing invokes it — the Sprint-0-era `ContentBlockerBootstrap.installBundledSnapshotIfNeeded()` unconditional-reinstall-on-launch is still the only thing that runs, and whoever wires up the first real caller must gate that call or it will silently revert a real update), StoreKit/premium purchase flow, multi-group rule composition, background scheduling, and downloaded-temp-file cleanup.
- Full design and implementation detail: [`docs/Architecture/TargetTopology.md`](docs/Architecture/TargetTopology.md), [`docs/superpowers/specs/2026-07-18-sprint2-update-pipeline-design.md`](docs/superpowers/specs/2026-07-18-sprint2-update-pipeline-design.md).

Sprint 1 (rule pipeline foundation) is **complete** on `dev`, all 13 tasks landed:
- A new `Filtering/` module (`ADBLX/Filtering/`) in the main app target only holds six single-purpose stage types — `FilterValidator`, `RuleCompiler`/`PassthroughRuleCompiler`, `RulePartitioner`/`PassthroughAdsPartitioner`, `FilterStore`, `AtomicRuleWriter`, `ReloadCoordinator` — sequenced by a `FilterPipeline` actor (constructed via `AppCompositionRoot`, dependency-injected, no singleton) into `validate → compile → partition → atomically write → persist metadata → reload`.
- `ContentBlockerBootstrap` collapsed from Sprint 0's direct `FileManager`/`SFContentBlockerManager` calls to a single delegation into `FilterPipeline.installBundledSnapshotIfNeeded()`.
- `ADBLXAdsBlocker`'s read path now points at `Compiled/Ads.json` (the pipeline's real output location) instead of Sprint 0's `Rules/Ads.json`. The other 3 Content Blockers (`Privacy`/`Annoyances`/`Regional`) are still unmigrated — bundled `[]` only, same as Sprint 0.
- Still Sprint-1 scope only: bundled test fixtures, no networking (`PassthroughRuleCompiler` is a stub — real compilation lands post ADR-0001), single-filter (`ads-bundled`) only.
- Full design and implementation detail: [`docs/Architecture/TargetTopology.md`](docs/Architecture/TargetTopology.md), [`docs/Architecture/Logging.md`](docs/Architecture/Logging.md).

Sprint 0 (repository bootstrap) is complete on `dev`, all 5 commits landed:
- **Commit 1** — repo scaffolding (`Config/`, `docs/ADR/`, `docs/Architecture/`, lint/format config).
- **Commit 2** — migrated the hand-authored `ADBLX.xcodeproj` to XcodeGen (`project.yml` is now the source of truth; see [`README.md`](README.md)).
- **Commit 3** — added all 6 extension targets (4 Content Blockers, `ADBLXPacketTunnel`, `ADBLXSafariWebExtension`) as placeholders — they build, but have no capabilities and no runtime behavior yet.
- **Commit 4** — added the `group.com.ADBLX.shared` App Group entitlement to 6 targets (`ADBLXPacketTunnel` deferred — Personal Team can't provision its Network Extension entitlement) and a GitHub Actions CI workflow (generate/drift-check/build/`ADBLXTests`).
- **Commit 5** — validated the runtime pipeline: `ADBLXAdsBlocker` reads 70 synthetic rules from the App Group (with permanent bundle fallback), `ContentBlockerBootstrap` installs and reloads once per install, minimal MetricKit receiver, `Performance/Baselines.md` and `docs/Architecture/ManualVerification.md` established. Getting this actually working on a real device/simulator required two follow-up fixes: extensions were never embedded in `ADBLX.app` (`project.yml` had no `dependencies`/`embed: true`), and extension bundle IDs weren't nested under the app's as iOS requires (`com.ADBLX.ADBLXAdsBlocker` → `com.ADBLX.ADBLX.AdsBlocker`) — installs failed outright until both were fixed. Also pinned `DEVELOPMENT_TEAM` in `project.yml` so Xcode's Signing & Capabilities Team selection survives `xcodegen generate` instead of resetting on every regenerate. Manual verification (all 9 steps of `ManualVerification.md`) fully passed, including fallback: extension enabled in Safari, reload confirmed via log, a test request to `ads1.example.com` was blocked, and removing `Rules/Ads.json` from the App Group and toggling the extension confirmed `ADBLXAdsBlocker` falls back to its bundled `blockerList.json` and keeps blocking correctly (log evidence for both paths — `AppGroup` category, fixed to hardcode subsystem `com.ADBLX.ADBLX` since `Bundle.main.bundleIdentifier` resolves to the extension's own ID inside an extension process, not the app's).

Full current target topology, folder layout, and what's deliberately not implemented yet: [`docs/Architecture/TargetTopology.md`](docs/Architecture/TargetTopology.md).

Sprint 0, Sprint 1, and Sprint 2 are done. The next major milestone is Sprint 3 — wiring a real caller of `UpdateCoordinator.run()` (a "Check for Updates" button, launch-time check, or `BGAppRefreshTask`), which requires first gating or retiring `ContentBlockerBootstrap`'s unconditional bundled-snapshot reinstall so it can't revert a real update — plus real SafariConverterLib-backed compilation (gated on ADR-0001) and multi-filter/non-`.ads`-group support in the pipeline.
