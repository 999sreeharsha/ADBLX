# ADBLX Filter Registry (v1)

## Purpose

This document freezes the v1 catalog of filter lists ADBLX distributes
through the backend. It answers one question only:

> **What filters exist?**

It deliberately does not answer:

- When filters update (client/`UpdateCoordinator` concern, PRD §6.2/§5.1).
- What order filters compile in (compiler/manifest concern).
- What today's published version/checksum is (manifest concern, Commit 3).

See `docs/superpowers/specs/2026-07-26-sprint6-commit1-backend-repo-architecture-design.md`
for the backend's directory architecture and ownership model.

## Registry inclusion criteria

A filter is registered in this document only if all of the following are
true:

- Supported by the current ADBLX architecture (maps to one of the four
  `FilterGroup` Content Blocker extensions below — no DNS-layer lists).
- Intended for distribution in v1.
- Has a production-ready upstream source (a real, currently maintained list
  — not a list that still needs to be built or curated).
- Has licensing reviewed sufficiently for inclusion.

Lists that don't yet satisfy all four criteria are documented under
**Future candidates**, not registered as filters.

Internal IDs are stable identifiers used by the manifest and client. Once
published, they are never renamed; new IDs are introduced instead.

## Supported FilterGroups

ADBLX compiles four Safari Content Blocker extensions (PRD §6.1, Layer 1).
These are the only groups this registry covers — DNS-layer lists (PRD Layer
2) are out of scope for this backend until a DNS distribution model exists.

- Ads
- Privacy
- Annoyances
- Regional

## Registered Filters

Each entry's upstream download URL is the canonical URL current at the time
of writing. Upstream projects occasionally move their hosting; the backend
maintainer owns keeping this URL current, not this document's freeze.

### Ads

| Field | Value |
|---|---|
| Display name | EasyList |
| Internal ID | `easylist` |
| Upstream project | EasyList |
| Upstream download URL | https://easylist.to/easylist/easylist.txt |
| License | CC BY-SA 3.0 / GPLv3 |
| ADBLX FilterGroup | Ads |
| Default enabled (fresh installation) | ✅ |
| Premium | ❌ |
| Notes | — |

### Privacy

| Field | Value |
|---|---|
| Display name | EasyPrivacy |
| Internal ID | `easyprivacy` |
| Upstream project | EasyList |
| Upstream download URL | https://easylist.to/easylist/easyprivacy.txt |
| License | CC BY-SA 3.0 / GPLv3 |
| ADBLX FilterGroup | Privacy |
| Default enabled (fresh installation) | ✅ |
| Premium | ❌ |
| Notes | — |

### Annoyances

| Field | Value |
|---|---|
| Display name | Fanboy Annoyances |
| Internal ID | `fanboy-annoyances` |
| Upstream project | EasyList (Fanboy) |
| Upstream download URL | https://easylist.to/easylist/fanboy-annoyance.txt |
| License | CC BY-SA 3.0 |
| ADBLX FilterGroup | Annoyances |
| Default enabled (fresh installation) | ❌ |
| Premium | ✅ |
| Notes | Gated per PRD §5.1 ("Cookie-banner / annoyance filters" is a Premium feature). |

### Regional

No production filter is registered for v1.

Future direction:

- `shield-india` — proprietary Indian web ad-network list (see PRD Appendix
  C). Not yet built; requires the publisher audit described there before it
  can be registered.
- EasyList regional variants — no specific variant has been selected yet.

## Future candidates

Lists named in the PRD (Appendix A/C) that don't yet meet the inclusion
criteria above, kept here so they aren't rediscovered from scratch:

| List | Group | Why deferred |
|---|---|---|
| AdGuard Base | Ads | Overlaps heavily with EasyList; deferred to avoid redundant rules/compile size in v1. |
| SHIELD proprietary fixes | Ads | Not yet built (PRD Appendix C direction). |
| Peter Lowe's | Privacy | Listed as CB + DNS in PRD Appendix A; this registry is CB-only for v1, and the list spans both layers. |
| `shield-india` | Regional | Not yet built — requires the publisher audit in PRD Appendix C. |
| EasyList regional variants | Regional | No specific variant selected. |

DNS-layer-only lists (OISD, HaGeZi Multi) are out of scope entirely until a
DNS distribution model is designed — see Sprint 6 Commit 1's decision to
scope the backend to the four Content Blocker `FilterGroup`s.

## Deliverables (this commit)

- `backend/docs/FilterRegistry.md` (this file).
- A frozen v1 registry of supported filter lists.
- No downloader, no manifest generation, no automation.

Manifest schema design (Commit 3) references these registry entries.
