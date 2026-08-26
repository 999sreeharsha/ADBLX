# 0011 — Web Extension rule data: generation lifecycle and publication

**Date:** 2026-08-25
**Status:** Proposed

## Context

ADR-0010 fixed the boundary: Layer 3's JS/native logic is bundled at app
release, and only inert data is updatable via the existing filter
pipeline's App Group mechanism. This ADR decides *how that data is
structured, validated, published, and consistently read* — reusing the
semantics Sprint 8B's DNS generation model established (immutable
directories + atomic pointer), not its types or file formats, since the
content is a different domain: site-match rules, CSS selectors, YouTube
configuration data, and anti-adblock intervention data — not a DNS
blocklist.

## Decision

### 1. Self-contained generation snapshots

Each generation is one complete, internally consistent bundle of every
Layer 3 data type together — site rules, YouTube configuration, and
anti-adblock configuration are versioned as a single unit, not as three
independently-versioned artifacts. Rationale: a YouTube configuration
entry could reference a selector defined in the site-rules set (e.g., a
shared "player container" selector reused across YouTube handling and
general cosmetic filtering); versioning them separately risks a native
handler serving a valid-in-isolation but mutually inconsistent combination
across a partial update. One generation number describes one fully
consistent state of everything Layer 3 needs.

```text
group.com.ADBLX.shared/
└── WebExtension/
    ├── generations/
    │   ├── 000001/
    │   │   ├── manifest.json      (schemaVersion, generation, checksums,
    │   │   │                       rule/selector counts, per-section sizes)
    │   │   └── rules.json         (siteRules + youtubeConfiguration +
    │   │                           antiAdblockConfiguration, combined)
    │   └── 000002/
    │       └── ...
    ├── staging/                    (transient, same role as DNS's staging/)
    └── current.json                (atomic pointer: active generation number
                                      + publishedAt, mirrors DNSCurrentPointer)
```

### 2. Entitlement state is not part of the generation

Premium entitlement status is written as its own small, independently
updatable file — `WebExtension/entitlement.json` — sitting alongside, not
inside, the generation directories. Rationale: entitlement transitions
(subscription lapse, renewal, restore) happen on their own schedule,
unrelated to filter-content updates. Folding entitlement into the
generation would force every StoreKit-driven entitlement change to bump
the generation number and re-publish the entire ruleset, conflating two
independent lifecycles and adding unnecessary compile/publish work to a
purely-local state change. `SafariWebExtensionHandler` reads both files
independently and combines them into a single response, per ADR-0012.

### 3. Validation and size budget, enforced at staging

Before a staged generation can be atomically published:
- Schema validation (structurally well-formed per the schema version
  declared).
- Checksum verification (same SHA-256 pattern as the DNS artifact and
  Publisher's manifest checksums — consistency across the project's
  artifact types, not a new convention).
- **An explicit maximum artifact size**, enforced as a hard validation
  failure if exceeded. The exact number is not set in this ADR — Layer 3
  content (selectors, host matches, configuration values) has a very
  different size profile than a DNS hosts-list, and a real cap should be
  set from actual authored content during implementation, not invented
  here. What this ADR commits to is that an oversized staged generation
  is *rejected*, never silently published — an unbounded Layer 3 artifact
  is exactly the kind of scope-creep this project has repeatedly guarded
  against (the same discipline as ADR-0008's memory-ceiling caution).

### 4. Atomic publish, same mechanism as existing pipelines

Staging → validate → write the new generation directory in full →
atomically publish (temp + rename, via the existing `AtomicRuleWriter`
utility — reused directly, not reimplemented) → atomically swap
`current.json`'s pointer. This is the same two-phase atomicity
(complete-directory-then-pointer-swap) Sprint 8B already proved out for
DNS generations, applied to a new data domain.

### 5. Native-reader consistency by construction, not by locking

Because each generation directory is immutable once published (never
edited in place), a reader that has resolved `current.json` to generation
N and is mid-read of `generations/00000N/` is safe regardless of whether
publication moves the pointer to N+1 concurrently — there is no partial
or torn read to guard against, the same property that made DNS's
generation swap safe under live query traffic. `SafariWebExtensionHandler`
reads `current.json`, then reads that specific generation directory,
per request — no persistent cross-request state, no lock needed beyond
what atomic file operations already provide.

### 6. Retention and fallback

Retain the active generation plus the immediately prior one as
last-known-good, prune older generations after a successful publish —
matching the pattern already implemented for DNS
(`sprint_8b_final_closure_evidence.md`'s Generation 1/2 pruning
behavior). If a staged generation fails validation, publication is
aborted and the previous generation remains fully served — no partial
state is ever reachable through `current.json`.

## Performance and battery

- **Main thread:** none — generation building, validation, and publication
  happen off-main in the main app, consistent with the existing pipeline.
- **Memory:** bounded to one generation being staged plus the currently
  active generation resident in the native handler at request time. The
  Safari Web Extension's native handler process doesn't carry the same
  officially-documented hard memory ceiling as Content Blocker or Network
  Extension providers, but that's a reason to measure its actual behavior
  under real Layer 3 content during implementation, not a reason to skip
  measuring — same discipline as ADR-0008's correction on the DNS tunnel's
  memory figure.
- **Disk I/O:** update-driven only, one staging write plus one atomic
  publish per update cycle; no per-page-load disk I/O — the native
  handler reads from the App Group only when the JS side actually
  requests state (ADR-0012's pull model), not on a schedule.
- **Network/radio:** zero additional wakeups — Layer 3 updates ride the
  existing filter-update transaction, not a separate fetch cycle.
- **Battery:** negligible outside actual update events; steady-state cost
  is bounded by ADR-0010's event/match-driven activation ceiling, not by
  anything this ADR introduces.

## Consequences

- `ADBLXShared` gains new types for the Web Extension generation
  manifest/pointer, parallel in spirit to `DNSGenerationManifest`/
  `DNSAppGroupPaths` but distinct types — no shared inheritance forced
  between DNS and Web Extension artifacts just because the directory
  shape rhymes.
- The entitlement file's freshness (how often it's actually correct
  relative to real StoreKit state, and what "correct enough" means) is
  ADR-0012's concern, not this one's — this ADR only decides *where* it
  lives and that it's decoupled from generation numbering.
- A concrete size budget must be set from real Layer 3 content before
  Sprint 9 implementation is considered complete — this is a named open
  item carried into task-level design, not resolved here.
