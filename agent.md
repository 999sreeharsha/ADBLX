# Agent Notes — SHIELD (ADBLX)

iOS/iPadOS/Mac(Catalyst) ad blocker. Full spec: [docs/adblock-prd-v1.1.md](docs/adblock-prd-v1.1.md).

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
Fresh Xcode scaffold only (`ADBLX/`, `ADBLXTests/`, `ADBLXUITests/`) — none of the above is implemented yet. Sprint 1 target: app + 4 content blocker extensions + App Group with bundled-snapshot blocking working end-to-end.
