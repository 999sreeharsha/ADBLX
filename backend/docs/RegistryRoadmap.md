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
| Peter Lowe's | Privacy | Listed as CB + DNS in PRD Appendix A; this registry is CB-only for v1, and the list spans both layers. |
| `shield-india` | Regional | Not yet built — requires the publisher audit in PRD Appendix C. |
| EasyList regional variants | Regional | No specific variant selected. |

DNS-layer-only lists (OISD, HaGeZi Multi) are out of scope entirely until a
DNS distribution model is designed — see Sprint 6 Commit 1's decision to
scope the backend to the four Content Blocker `FilterGroup`s.
