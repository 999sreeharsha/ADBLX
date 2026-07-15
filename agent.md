# Agent Notes — SHIELD (ADBLX)

iOS/iPadOS ad blocker. Full spec: [docs/adblock-prd-v1.1.md](docs/adblock-prd-v1.1.md).

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
Sprint 0 (repository bootstrap) is in progress on `dev`, Commits 1–4 of 5 complete:
- **Commit 1** — repo scaffolding (`Config/`, `docs/ADR/`, `docs/Architecture/`, lint/format config).
- **Commit 2** — migrated the hand-authored `ADBLX.xcodeproj` to XcodeGen (`project.yml` is now the source of truth; see [`README.md`](README.md)).
- **Commit 3** — added all 6 extension targets (4 Content Blockers, `ADBLXPacketTunnel`, `ADBLXSafariWebExtension`) as placeholders — they build, but have no capabilities and no runtime behavior yet.
- **Commit 4** — added the `group.com.ADBLX.shared` App Group entitlement to 6 targets (`ADBLXPacketTunnel` deferred — Personal Team can't provision its Network Extension entitlement) and a GitHub Actions CI workflow (generate/drift-check/build/`ADBLXTests`).

Full current target topology, folder layout, and what's deliberately not implemented yet: [`docs/Architecture/TargetTopology.md`](docs/Architecture/TargetTopology.md).

Remaining Sprint 0 work: Commit 5 (functional verification — App Group round-trip, real bundled rule snapshot, `reloadContentBlocker()`, MetricKit, performance baselines).
