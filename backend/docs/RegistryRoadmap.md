# ADBLX Registry Roadmap

## Purpose

This document tracks filters and lists under evaluation for future
inclusion in `backend/registry/filters.json`. It is hand-authored and never
generated — unlike `backend/docs/FilterRegistry.md`, which is generated
from the registry (Sprint 7).

Entries here are not registered filters: they have no `id` in the
publisher's sense, no `enabledByDefault`/`premium` decision, and sometimes
no confirmed `group`. A list moves from this document into
`backend/registry/filters.json` only once it satisfies every inclusion
criterion in `FilterRegistry.md`'s "Registry inclusion criteria" section.

## Regional group — future direction

No production filter is registered for the Regional group in v1.

- `shield-india` — proprietary Indian web ad-network list (see PRD Appendix
  C). Not yet built; requires the publisher audit described there before it
  can be registered.
- EasyList regional variants — no specific variant has been selected yet.

## Future candidates

| List | Group | Why deferred |
|---|---|---|
| AdGuard Base | Ads | Overlaps heavily with EasyList; deferred to avoid redundant rules/compile size in v1. |
| SHIELD proprietary fixes | Ads | Not yet built (PRD Appendix C direction). |
| `shield-india` | Regional | Not yet built — requires the publisher audit in PRD Appendix C. |
| EasyList regional variants | Regional | No specific variant selected. |
| HaGeZi Multi | DNS | Deferred pending licensing attribution review (GPL-3.0) and DNS CDN distribution model. |

## DNS Layer Status

- **Operational Snapshot (v1):** `oisd` and `peter-lowe` are bundled on-device in `ADBLX/Resources/Filters/DNS/` as the initial local operational snapshot (pending open pre-launch legal sign-off per PRD §14 and `agent.md`).
- **CDN Distribution Model:** DNS blocklist is currently bundled-only with no CDN live-update pathway; every DNS rule change requires a full app release until the DNS registry and manifest pipeline work is designed and integrated.
- **HaGeZi Multi:** Tracked as a future candidate in the roadmap pending licensing clearance.
