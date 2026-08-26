# 0013 — Layer 3 capability boundary and explicit non-goals

**Date:** 2026-08-25
**Status:** Proposed

## Context

ADR-0010 fixed execution (Manifest V3, bundled logic, no remote code).
ADR-0011 fixed data publication (self-contained generations, independent
entitlement file). ADR-0012 fixed the transport (pull-only, two-axis
fail model). None of those decide *what Layer 3 is actually allowed to
do* — which is the PRD's original, dangerously broad wording: "YouTube-in-
Safari handling, cosmetic filtering, and anti-adblock handling." This ADR
draws the line precisely enough that a future contributor can look at a
proposed feature and get a yes/no answer without re-litigating the whole
architecture.

## Decision

### 1. Admitted categories

Layer 3 is scoped to exactly three functional categories, each defined by
*why it can't live in Layer 1* (Content Blocker JSON has no JS, no DOM
access, no procedural logic — per PRD Appendix B.1):

- **YouTube-in-Safari.** Intervention on youtube.com pages specifically,
  limited to what requires runtime DOM/page-state inspection that a
  static network or cosmetic rule cannot express (e.g., detecting an
  ad-break UI state, not merely blocking a known ad-server domain, which
  belongs in Layer 1/2 already).
- **Procedural cosmetic filtering.** Element hiding/removal that depends
  on runtime conditions a static CSS selector can't express alone —
  content that appears only after a DOM mutation, or a hide decision that
  depends on more than "does this selector match." Anything expressible
  as a static selector belongs in the Content Blocker's declarative
  `css-display-none` action instead, not here — Layer 3 is for the
  residue Layer 1 genuinely cannot reach, not a preferred/easier place to
  put ordinary cosmetic rules.
- **Anti-adblock circumvention, narrowly scoped.** Interventions against
  a specific, named, documented anti-adblock technique (e.g., a page that
  detects a blocked network request and shows an interstitial) — each
  supported technique is its own named, bounded intervention, not a
  general "detect and defeat anti-adblock scripts" capability.

### 2. Admission test for any future feature

Before any new Layer 3 feature is added — YouTube, cosmetic, anti-adblock,
or otherwise — it must pass all of the following, checked in this order:

1. **Layer boundary check.** Can this be expressed as a static Content
   Blocker rule (network block, `css-display-none`, `make-https`) instead?
   If yes, it does not belong in Layer 3 regardless of convenience.
2. **Fixed-engine/updatable-data check.** Does this feature's *logic*
   (the algorithm deciding what to do) change, or only its *data*
   (selectors, thresholds, host matches, feature flags)? If the feature
   requires new logic, it requires an app release (per ADR-0010) — a
   feature that's designed assuming it can ship logic changes through the
   filter CDN fails this test outright.
3. **Activation-scope check.** Can this run only on event/match-driven
   activation (per ADR-0010's Decision 6), with no global always-on
   observation? A feature that needs to watch every page "just in case"
   fails this test.
4. **Performance/battery admission criteria** (explicit, not left as "TBD
   per feature"):
   - Content-script injection cost measured on a representative matched
     page: main-thread impact must be negligible relative to normal page
     load — a specific numeric budget (e.g., added parse/first-paint
     delay) is set during that feature's own task-level design, not
     invented here, but *some* explicit number is required before the
     feature ships, not "it felt fine."
   - Any DOM `MutationObserver` used must be scoped to the narrowest
     possible subtree and disconnected when no longer needed — an
     observer with unbounded scope or indefinite lifetime running without
     a defined lifecycle boundary or disconnect condition on a long-lived
     tab violates the event/match-driven activation ceiling.
   - Memory: bounded and released when the content script's page context
     is torn down (page navigation/close) — no cross-page accumulation.
5. **Anti-adblock scoping check** (specific to that category only): is
   the countermeasure named and bounded to a specific, documented
   technique? A generic "defeat anti-adblock detection" capability is
   rejected outright — that's an open-ended arms race, not a bounded
   feature, and is explicitly a non-goal (below).

A feature that fails any step is out of scope for Layer 3 as currently
architected, full stop — not "deprioritized," not "revisit later inside
this ADR." A genuinely new category of need reopens this ADR or spawns a
new one, the same discipline ADR-0004 and ADR-0006 already established
for the DNS layer.

### 3. Explicit non-goals

Layer 3 does **not**:

- Implement a general-purpose filter-syntax interpreter (no EasyList/
  AdGuard advanced-rule syntax parsed and executed at runtime — this is
  the "miniature uBlock Origin in JavaScript" explicitly rejected at the
  start of Sprint 9's design pass).
- Parse raw upstream filter lists on-device in JS — any list-derived
  content Layer 3 needs is pre-processed into the fixed schema
  (ADR-0011) by the main app, same as every other filter data path in
  this project.
- Run always-on, global DOM observation on pages outside its declared
  match patterns.
- Attempt native YouTube *app* ad blocking — unchanged from the PRD's
  original NG1, restated here because Layer 3 is the layer someone might
  mistakenly think could reach it; it categorically cannot (different
  process, no extension surface at all).
- Implement a general anti-adblock-detection countermeasure — only
  specific, named, bounded techniques are supported, added one at a time
  through this ADR's admission test.
- Fetch or execute remote code of any kind — restated from ADR-0010
  because it's the boundary most likely to be quietly violated by a
  well-intentioned "just fetch the latest selector logic" shortcut under
  time pressure.

### 4. YouTube mechanism is explicitly deferred, not approved

This ADR approves that YouTube-in-Safari is an admitted *category* of
Layer 3 responsibility. It does **not** approve, specify, or imply any
particular detection or intervention mechanism (DOM markers watched,
selectors targeted, what constitutes "an ad is showing," what
intervention is taken). That is a separate, subsequent task-level design
document, to be evaluated against this ADR's admission test like any
other feature — including the performance/battery criteria in Decision 2
— before implementation begins. "YouTube-in-Safari: admitted category" in
this ADR must never be read downstream as "YouTube mechanism: designed
and approved."

## Performance and battery

This ADR sets *criteria*, not a cost figure of its own — no Layer 3
feature exists yet to measure. Its cost contribution is the ceiling every
future feature is measured against: negligible main-thread impact on
matched pages, no unbounded observers, no cross-page memory
accumulation, and no activation outside declared match patterns. Each
concrete feature's actual numbers are a task-level deliverable.

## Consequences

- Any Layer 3 feature proposal going forward is checked against Decision
  2's five-step test before design work starts, not after implementation
  reveals a problem.
- The YouTube mechanism, procedural-cosmetic mechanism, and each
  anti-adblock intervention are each their own task-level design
  artifact, evaluated independently against this ADR — not bundled into
  one "Layer 3 behavior" deliverable.
- If a genuinely new category of Layer 3 need emerges later (something
  that isn't YouTube, cosmetic, or anti-adblock but still requires
  runtime JS), it requires reopening or superseding this ADR explicitly,
  not quietly stretching one of the three existing categories to cover it.
